class_name DotBoundedBuffer
extends RefCounted

## A first-in first-out queue that cannot grow without limit, and says so when it sheds. Three addons each had their own: a log queue, a telemetry queue and a report outbox. A backed-up collector must cost history, never memory.
##
## [member capacity] bounds the item count and [member max_weight] an optional cost (bytes, say) that [member weigher] estimates per item; 0 means unlimited for both. When a push goes over, [constant Policy.DROP_OLDEST] discards from the front and [constant Policy.REFUSE] turns the new item away. Every loss is counted ([member dropped], [member refused], [member dropped_weight]).
##
## Dropping and taking move a head index instead of shifting the array, so a full buffer costs the same per push as an empty one; the array is compacted only when half of it is dead space.

enum Policy {
	DROP_OLDEST,  ## Discard from the front; keeps the most recent.
	REFUSE,  ## Turn the incoming item away; keeps the earliest.
}

## Most items held; 0 is unlimited.
var capacity: int = 0
## Most total weight held; 0 is unlimited. Needs [member weigher].
var max_weight: int = 0
## Maps an item to its weight (an int). Empty means every item weighs 0 and [member max_weight] does nothing.
var weigher: Callable = Callable():
	set(value):
		weigher = value
		_weighed = weigher.is_valid()
var policy: Policy = Policy.DROP_OLDEST

## Items discarded from the front since the counters were last reset.
var dropped: int = 0
## Weight of those items.
var dropped_weight: int = 0
## Items turned away by [constant Policy.REFUSE].
var refused: int = 0
## Weight of those items.
var refused_weight: int = 0
## Most items ever held at once.
var high_water: int = 0

var _items: Array = []
var _head: int = 0
var _weight: int = 0
var _weighed: bool = false


func _init(p_capacity: int = 0, p_policy: Policy = Policy.DROP_OLDEST) -> void:
	capacity = maxi(0, p_capacity)
	policy = p_policy


func size() -> int:
	return _items.size() - _head


func is_empty() -> bool:
	return _items.size() == _head


## Total weight held (0 without a weigher).
func weight() -> int:
	return _weight


## Adds [param item]. Returns false when it was refused or when it displaced older items, so a caller can tell a clean push from a lossy one.
func push(item: Variant) -> bool:
	if _weighed:
		return _push_checked(item)
	# The common case, kept short because it runs for every event: no weights.
	if policy == Policy.REFUSE and capacity > 0 and _items.size() - _head >= capacity:
		refused += 1
		return false
	_items.append(item)
	var held := _items.size() - _head
	if capacity > 0 and held > capacity:
		var over := held - capacity
		_head += over
		dropped += over
		if _head * 2 >= _items.size():
			_items = _items.slice(_head)
			_head = 0
		held = capacity
		if held > high_water:
			high_water = held
		return false
	if held > high_water:
		high_water = held
	return true


## Removes and returns up to [param n] items, oldest first; 0 takes all.
func take(n: int = 0) -> Array:
	var count := size() if n <= 0 else mini(n, size())
	var out := _items.slice(_head, _head + count)
	_release(out)
	_head += count
	_compact()
	return out


## Removes up to [param n] oldest items without building an array of them; 0 removes all. Returns how many went.
func discard(n: int = 0) -> int:
	var count := size() if n <= 0 else mini(n, size())
	if _weighed:
		for i in range(_head, _head + count):
			_weight -= int(weigher.call(_items[i]))
		_weight = maxi(0, _weight)
	_head += count
	_compact()
	return count


## Up to [param n] oldest items without removing them; 0 returns all.
func peek(n: int = 0) -> Array:
	var count := size() if n <= 0 else mini(n, size())
	return _items.slice(_head, _head + count)


## Puts a batch whose delivery failed back at the front, in order. Over the bound the front is dropped, whatever the policy: the batch was already accepted once and refusing it now would lose records the sender counted as kept. With [param keep_oldest] the newest are dropped instead, for a sender that would rather lose the latest than the history it already tried to ship.
func requeue(batch: Array, keep_oldest: bool = false) -> void:
	if batch.is_empty():
		return
	_items = batch + _items.slice(_head)
	_head = 0
	if _weighed:
		for item in batch:
			_weight += int(weigher.call(item))
	if keep_oldest:
		_shed_newest()
	else:
		_shed()
	high_water = maxi(high_water, size())


## Empties the buffer and returns how many items were in it. The counters stay.
func clear() -> int:
	var n := size()
	_items.clear()
	_head = 0
	_weight = 0
	return n


## Everything held, oldest first, as a copy: what a game writes to disk so unsent items survive a restart.
func to_array() -> Array:
	return _items.slice(_head)


## Replaces the contents with [param data] (from [method to_array]). Anything over the bound is dropped from the front and counted.
func load_array(data: Array) -> void:
	_items = data.duplicate()
	_head = 0
	_weight = 0
	if _weighed:
		for item in _items:
			_weight += _weigh(item)
	_shed()
	high_water = maxi(high_water, size())


## Zeroes the drop and refusal counters ([member high_water] is kept).
func reset_counters() -> void:
	dropped = 0
	dropped_weight = 0
	refused = 0
	refused_weight = 0


func describe() -> Dictionary:
	return {
		"size": size(), "weight": _weight, "capacity": capacity, "max_weight": max_weight,
		"high_water": high_water, "dropped": dropped, "dropped_weight": dropped_weight, "refused": refused,
		"policy": "drop_oldest" if policy == Policy.DROP_OLDEST else "refuse",
	}


func _push_checked(item: Variant) -> bool:
	var w := 0
	if _weighed:
		w = int(weigher.call(item))
	if policy == Policy.REFUSE and _would_overflow(w):
		refused += 1
		refused_weight += w
		return false
	_items.append(item)
	_weight += w
	var lost := false
	if (capacity > 0 and size() > capacity) or (max_weight > 0 and _weight > max_weight):
		lost = _shed()
	high_water = maxi(high_water, size())
	return not lost


func _weigh(item: Variant) -> int:
	return int(weigher.call(item)) if _weighed else 0


func _release(items: Array) -> void:
	if _weighed:
		for item in items:
			_weight -= _weigh(item)
		_weight = maxi(0, _weight)


func _would_overflow(incoming_weight: int) -> bool:
	if capacity > 0 and size() >= capacity:
		return true
	return max_weight > 0 and _weight + incoming_weight > max_weight


## Drops from the front until the bound holds, never below one item: a single item heavier than the whole budget must still be held, and a buffer that refuses everything is a worse failure than one oversized entry.
func _shed() -> bool:
	var lost := false
	if not _weighed and capacity > 0 and size() > capacity:
		# Nothing to weigh: drop the whole excess in one step.
		var over := size() - capacity
		_head += over
		dropped += over
		_compact()
		return true
	while _over():
		var gone: Variant = _items[_head]
		var w := _weigh(gone)
		_items[_head] = null
		_head += 1
		_weight -= w
		dropped += 1
		dropped_weight += w
		lost = true
	_weight = maxi(0, _weight)
	if lost:
		_compact()
	return lost


func _shed_newest() -> void:
	while _over():
		var gone: Variant = _items.pop_back()
		var w := _weigh(gone)
		_weight -= w
		dropped += 1
		dropped_weight += w
	_weight = maxi(0, _weight)


func _over() -> bool:
	if capacity > 0 and size() > capacity:
		return true
	return max_weight > 0 and _weight > max_weight and size() > 1


func _compact() -> void:
	if _head > 0 and (_head * 2 >= _items.size() or _head == _items.size()):
		_items = _items.slice(_head)
		_head = 0
