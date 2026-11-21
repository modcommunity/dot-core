extends Node

## Exercises [DotBoundedBuffer]: unlimited, drop-oldest and refuse bounds with their counters, weight budgets, take/peek/requeue order, the restore pair, and that a long run of pushes into a full buffer stays flat.

const CHECKS := 37

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("dot-core bounded buffer self-test")
	_unlimited()
	_drop_oldest()
	_refuse()
	_weight()
	_requeue()
	_restore()
	_churn()
	print("bounded buffer: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 or _passed != CHECKS else 0)


func _unlimited() -> void:
	var b := DotBoundedBuffer.new()
	for i in range(1000):
		b.push(i)
	_check(b.size() == 1000 and b.dropped == 0 and b.refused == 0, "capacity 0 holds everything and drops nothing")
	_check(b.high_water == 1000, "high water follows the size")
	_check(b.take(3) == [0, 1, 2] and b.size() == 997, "take returns the oldest first")
	_check(b.discard(7) == 7 and b.size() == 990 and b.peek(1) == [10], "discard removes the oldest without returning them")
	_check(b.take().size() == 990 and b.is_empty(), "take with 0 takes all")


func _drop_oldest() -> void:
	var b := DotBoundedBuffer.new(3)
	_check(b.push(1) and b.push(2) and b.push(3), "pushes within the bound are clean")
	_check(not b.push(4), "a push that displaces reports false")
	_check(b.to_array() == [2, 3, 4] and b.dropped == 1, "the oldest is dropped and counted")
	b.push(5)
	b.push(6)
	_check(b.peek() == [4, 5, 6] and b.dropped == 3, "the newest are kept")
	_check(b.peek(2) == [4, 5] and b.size() == 3, "peek leaves the items in place")
	b.reset_counters()
	_check(b.dropped == 0 and b.dropped_weight == 0 and b.refused == 0, "reset_counters zeroes the counters")
	_check(b.clear() == 3 and b.is_empty(), "clear reports how many it emptied")


func _refuse() -> void:
	var b := DotBoundedBuffer.new(2, DotBoundedBuffer.Policy.REFUSE)
	b.push(1)
	b.push(2)
	_check(not b.push(3), "a full refusing buffer turns the push away")
	_check(b.to_array() == [1, 2] and b.refused == 1 and b.dropped == 0, "the earliest are kept and the refusal counted")
	b.take(1)
	_check(b.push(3) and b.to_array() == [2, 3], "room after a take is usable again")


func _weight() -> void:
	var b := DotBoundedBuffer.new(0)
	b.max_weight = 10
	b.weigher = func(item: String) -> int: return item.length()
	b.push("aaaa")
	b.push("bbbb")
	_check(b.weight() == 8, "weight is the sum of the items")
	b.push("cccc")
	_check(b.to_array() == ["bbbb", "cccc"] and b.dropped == 1 and b.dropped_weight == 4 and b.weight() == 8, "weight over the budget drops the oldest")
	b.take(1)
	_check(b.weight() == 4, "take gives the weight back")
	b.clear()
	b.push("x".repeat(50))
	var d2 := DotBoundedBuffer.new(0)
	d2.weigher = func(item: String) -> int: return item.length()
	d2.push("abc")
	d2.push("de")
	d2.discard(1)
	_check(d2.weight() == 2, "discard gives the weight back")
	_check(b.size() == 1 and b.dropped == 1, "one item over the whole budget is still held")
	var r := DotBoundedBuffer.new(0, DotBoundedBuffer.Policy.REFUSE)
	r.max_weight = 5
	r.weigher = func(item: String) -> int: return item.length()
	r.push("abc")
	_check(not r.push("def") and r.refused == 1 and r.weight() == 3, "a refusing buffer turns away what would break the budget")
	var u := DotBoundedBuffer.new(0)
	u.max_weight = 5
	u.push("abcdefghij")
	u.push("abcdefghij")
	_check(u.size() == 2 and u.weight() == 0, "max_weight does nothing without a weigher")


func _requeue() -> void:
	var b := DotBoundedBuffer.new(5)
	for i in range(5):
		b.push(i)
	var batch := b.take(3)
	b.push(5)
	b.requeue(batch)
	_check(b.to_array() == [1, 2, 3, 4, 5] and b.dropped == 1, "requeue stays within the bound")
	var c := DotBoundedBuffer.new(10)
	for i in range(6):
		c.push(i)
	var first := c.take(4)
	c.requeue(first)
	_check(c.to_array() == [0, 1, 2, 3, 4, 5], "a requeued batch goes back in front, in order")
	var d := DotBoundedBuffer.new(4, DotBoundedBuffer.Policy.REFUSE)
	for i in range(4):
		d.push(i)
	var held := d.take(2)
	d.push(8)
	d.push(9)
	d.requeue(held)
	_check(d.to_array() == [2, 3, 8, 9], "requeue over the bound drops from the front even when refusing")
	_check(d.dropped == 2, "the displaced are counted")
	var k := DotBoundedBuffer.new(3)
	k.push(7)
	k.requeue([1, 2, 3], true)
	_check(k.to_array() == [1, 2, 3] and k.dropped == 1, "keep_oldest drops the newest over the bound")
	var w := DotBoundedBuffer.new(0)
	w.max_weight = 100
	w.weigher = func(item: int) -> int: return item
	w.push(10)
	w.push(20)
	var out := w.take(1)
	w.requeue(out)
	_check(w.weight() == 30, "requeue restores the weight")


func _restore() -> void:
	var a := DotBoundedBuffer.new(0)
	for i in range(5):
		a.push(i)
	a.take(2)
	var saved := a.to_array()
	_check(saved == [2, 3, 4], "to_array skips what was taken")
	var b := DotBoundedBuffer.new(2)
	b.load_array(saved)
	_check(b.to_array() == [3, 4] and b.dropped == 1, "load_array drops the front over the bound and counts it")
	saved.append(99)
	_check(b.size() == 2, "load_array copies its input")


func _churn() -> void:
	var b := DotBoundedBuffer.new(100)
	for i in range(100000):
		b.push(i)
	_check(b.size() == 100 and b.dropped == 99900, "a hundred thousand pushes into a bound of 100 leave 100")
	_check(b.peek(1) == [99900] and b.take(0).size() == 100, "and the newest hundred")
	var q := DotBoundedBuffer.new(0)
	for i in range(1000):
		q.push(i)
		if i % 3 == 0:
			q.take(2)
	_check(q.size() == 333, "interleaved takes keep the count right")
	var after := q.to_array()
	_check(after.size() == q.size() and after[0] < after[after.size() - 1], "and the order")
	_check(DotBoundedBuffer.new(-5).capacity == 0, "a negative capacity means unlimited")
	_check(DotBoundedBuffer.new(7).describe()["capacity"] == 7, "describe reports the bound")


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: %s" % what)
