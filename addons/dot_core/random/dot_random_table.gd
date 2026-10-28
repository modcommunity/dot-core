@tool
class_name DotRandomTable
extends Resource

## A weighted table of ids with three draw policies: WITH_REPLACEMENT (independent), WITHOUT_REPLACEMENT (a deck), PITY (weight climbs per miss).
## It draws ids and knows nothing about what they are, so it validates and draws on a server without the content. Set [member pity_after] or the base weight stops meaning anything;
## [method measure_rate] gives the realised rate.

enum Policy {
	## Independent draws. The default, and the only one with no memory.
	WITH_REPLACEMENT,
	## A shuffled deck, reshuffled when exhausted.
	WITHOUT_REPLACEMENT,
	## Weights climb on a miss and reset on a hit.
	PITY,
}

## An entry's id, weight and pity step, flattened into parallel arrays.
## Flat because a table is content: it round-trips through JSON and compares across server and client; [method to_dictionary] duplicates so no nested reference is shared.
@export var ids: Array[StringName] = []

## Base weights, aligned with [member ids]. Non-positive means "never".
@export var weights: PackedFloat32Array = PackedFloat32Array()

## How much weight an entry gains each time it is not drawn, under
## [constant Policy.PITY]. Zero is a normal entry.
@export var pity_steps: PackedFloat32Array = PackedFloat32Array()

## Tags per entry, for a caller that wants to filter before drawing.
@export var tags: Array[StringName] = []

@export var policy: Policy = Policy.WITH_REPLACEMENT

## Under [constant Policy.PITY], the ceiling a climbing weight stops at.
## Uncapped pity becomes a guarantee, and players learn the count and batch up to it.
@export_range(0.0, 100000.0, 0.1, "or_greater") var pity_cap: float = 1000.0

## Consecutive misses an entry takes before its weight starts climbing.
## Zero makes a measured 2% entry come out at 14.5%; set it past the mean interval (1/p) so only the unlucky tail is cut.
## The realised rate stays a little above base (the tail is removed); [method measure_rate] says by how much.
@export_range(0, 100000, 1) var pity_after: int = 0

## Mutable state for the two policies that have any.
var _pity: PackedFloat32Array = PackedFloat32Array()
var _misses: PackedInt32Array = PackedInt32Array()
var _deck: PackedInt32Array = PackedInt32Array()
var _deck_pos: int = 0


func size() -> int:
	return ids.size()


## Appends an entry. Returns self, so a table reads as a list.
func add(
	id: StringName,
	weight: float = 1.0,
	pity_step: float = 0.0,
	tag: StringName = &""
) -> DotRandomTable:
	ids.append(id)
	weights.append(weight)
	pity_steps.append(pity_step)
	tags.append(tag)
	_pity.append(0.0)
	return self


func index_of(id: StringName) -> int:
	return ids.find(id)


## Checks the table is usable before anything draws from it.
## Called at boot so a malformed table fails start-up, not a drop at the moment a player kills something.
func validate() -> DotResult:
	var n := ids.size()
	if n == 0:
		return DotResult.fail(DotError.CODE_INVALID, "a table with no entries draws nothing")
	if weights.size() != n or pity_steps.size() != n or tags.size() != n:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"a table's parallel arrays disagree",
			"%d ids, %d weights, %d pity steps, %d tags"
			% [n, weights.size(), pity_steps.size(), tags.size()]
		)

	var seen := {}
	var total := 0.0
	for i in range(n):
		var id := ids[i]
		if id == &"":
			return DotResult.fail(DotError.CODE_INVALID, "entry %d has no id" % i)
		if seen.has(id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"entry id '%s' appears twice" % id,
				"two entries with one id cannot be told apart by a pity counter"
			)
		seen[id] = true
		if weights[i] > 0.0:
			total += weights[i]
	if total <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "every weight in the table is zero or negative"
		)
	return DotResult.success(null)


## Draws one id. Returns [code]&""[/code] only when the table is unusable.
func draw(stream: DotRandomStream) -> StringName:
	if ids.is_empty() or stream == null:
		return &""
	match policy:
		Policy.WITHOUT_REPLACEMENT:
			return _draw_deck(stream)
		Policy.PITY:
			return _draw_pity(stream)
		_:
			var i := stream.next_weighted(_effective_weights())
			return ids[i] if i >= 0 else &""


## Draws [param count] ids, applying the policy between them.
func draw_many(stream: DotRandomStream, count: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for _i in range(maxi(0, count)):
		var id := draw(stream)
		if id == &"":
			break
		out.append(id)
	return out


## Draws from the entries carrying [param tag] only.
## Filtering here, not a second table, keeps one pity counter per entry.
func draw_tagged(stream: DotRandomStream, tag: StringName) -> StringName:
	var w := _effective_weights()
	for i in range(ids.size()):
		if tags[i] != tag:
			w[i] = 0.0
	var i := stream.next_weighted(w)
	if i < 0:
		return &""
	if policy == Policy.PITY:
		_apply_pity_result(i)
	return ids[i]


func _effective_weights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(ids.size())
	for i in range(ids.size()):
		var base: float = weights[i]
		if base <= 0.0:
			out[i] = 0.0
			continue
		out[i] = base + (_pity[i] if i < _pity.size() else 0.0)
	return out


func _draw_pity(stream: DotRandomStream) -> StringName:
	_ensure_pity()
	var i := stream.next_weighted(_effective_weights())
	if i < 0:
		return &""
	_apply_pity_result(i)
	return ids[i]


func _apply_pity_result(hit: int) -> void:
	_ensure_pity()
	for i in range(ids.size()):
		if pity_steps[i] <= 0.0:
			continue
		if i == hit:
			_pity[i] = 0.0
			_misses[i] = 0
			continue
		_misses[i] += 1
		if _misses[i] > pity_after:
			_pity[i] = minf(_pity[i] + pity_steps[i], pity_cap)


func _ensure_pity() -> void:
	if _pity.size() != ids.size():
		_pity.resize(ids.size())
	if _misses.size() != ids.size():
		_misses.resize(ids.size())


## A deck, dealt in order and reshuffled when it runs out.
## Weights become card counts, rounded with a floor of one, so fractional weights are never silently dropped to an empty deck.
func _draw_deck(stream: DotRandomStream) -> StringName:
	if _deck_pos >= _deck.size():
		_build_deck(stream)
	if _deck.is_empty():
		return &""
	var id := ids[_deck[_deck_pos]]
	_deck_pos += 1
	return id


func _build_deck(stream: DotRandomStream) -> void:
	var cards: Array = []
	var scale := 1.0
	var smallest := INF
	for i in range(ids.size()):
		if weights[i] > 0.0:
			smallest = minf(smallest, weights[i])
	if smallest < 1.0 and smallest > 0.0:
		scale = 1.0 / smallest

	for i in range(ids.size()):
		if weights[i] <= 0.0:
			continue
		var n := maxi(1, int(round(weights[i] * scale)))
		for _c in range(n):
			cards.append(i)

	_deck = PackedInt32Array(stream.next_shuffled(cards))
	_deck_pos = 0


## How many cards are left before the deck reshuffles. Zero for the other policies.
func deck_remaining() -> int:
	return maxi(0, _deck.size() - _deck_pos) if policy == Policy.WITHOUT_REPLACEMENT else 0


## How much extra weight an entry has accumulated from being missed.
func pity_of(id: StringName) -> float:
	var i := index_of(id)
	_ensure_pity()
	return _pity[i] if i >= 0 else 0.0


## How many draws in a row [param id] has been missed.
func misses_of(id: StringName) -> int:
	var i := index_of(id)
	_ensure_pity()
	return _misses[i] if i >= 0 else 0


## The rate [param id] actually comes out at, and the longest drought seen, over [param samples] draws.
## A pity table's base weight is not its rate; this is the only honest way to know. Runs on a copy, so live counters are untouched.
## Returns [code]{"rate": float, "longest_drought": int, "hits": int}[/code].
func measure_rate(stream: DotRandomStream, id: StringName, samples: int = 20000) -> Dictionary:
	var probe := DotRandomTable.from_dictionary(to_dictionary())
	var work := stream.duplicate_stream()
	var hits := 0
	var longest := 0
	var since := 0
	for _i in range(maxi(1, samples)):
		if probe.draw(work) == id:
			longest = maxi(longest, since)
			since = 0
			hits += 1
		else:
			since += 1
	longest = maxi(longest, since)
	return {
		"rate": float(hits) / float(maxi(1, samples)),
		"longest_drought": longest,
		"hits": hits,
	}


## Forgets the deck and every pity counter. The entries are untouched.
## Not named [code]reset_state[/code]: [Resource] already has that, GDScript parses it clean, and every call bound to the engine's method and did nothing.
func forget_state() -> void:
	_pity = PackedFloat32Array()
	_pity.resize(ids.size())
	_misses = PackedInt32Array()
	_misses.resize(ids.size())
	_deck = PackedInt32Array()
	_deck_pos = 0


## The mutable half, for a save file or a peer that has to agree with this one.
func state() -> Dictionary:
	return {
		"pity": Array(_pity),
		"misses": Array(_misses),
		"deck": Array(_deck),
		"deck_pos": _deck_pos,
	}


func adopt(s: Dictionary) -> void:
	_pity = PackedFloat32Array(s.get("pity", []))
	_misses = PackedInt32Array(s.get("misses", []))
	_ensure_pity()
	_deck = PackedInt32Array(s.get("deck", []))
	_deck_pos = int(s.get("deck_pos", 0))


## The whole table as plain data.
## Duplicated on the way out: Dictionaries and packed arrays are references, and this aliasing has shipped four times.
func to_dictionary() -> Dictionary:
	var out_ids := []
	for id in ids:
		out_ids.append(String(id))
	var out_tags := []
	for t in tags:
		out_tags.append(String(t))
	return {
		"ids": out_ids,
		"weights": Array(weights).duplicate(),
		"pity_steps": Array(pity_steps).duplicate(),
		"tags": out_tags,
		"policy": ["with_replacement", "without_replacement", "pity"][policy],
		"pity_cap": pity_cap,
		"pity_after": pity_after,
	}


static func from_dictionary(d: Dictionary) -> DotRandomTable:
	var t := DotRandomTable.new()
	var raw_ids: Array = d.get("ids", [])
	var raw_tags: Array = d.get("tags", [])
	var raw_weights: Array = d.get("weights", [])
	var raw_steps: Array = d.get("pity_steps", [])
	for i in range(raw_ids.size()):
		t.add(
			StringName(str(raw_ids[i])),
			float(raw_weights[i]) if i < raw_weights.size() else 1.0,
			float(raw_steps[i]) if i < raw_steps.size() else 0.0,
			StringName(str(raw_tags[i])) if i < raw_tags.size() else &""
		)
	t.policy = policy_from_name(str(d.get("policy", "with_replacement")))
	t.pity_cap = float(d.get("pity_cap", 1000.0))
	t.pity_after = int(d.get("pity_after", 0))
	return t


## The two ends of this round trip are tested together, in one check.
## Written beside each other because a reader with no case for a written key fails silently.
static func policy_from_name(s: String) -> Policy:
	match s.to_lower():
		"without_replacement", "deck":
			return Policy.WITHOUT_REPLACEMENT
		"pity":
			return Policy.PITY
		_:
			return Policy.WITH_REPLACEMENT


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var names := ["with replacement", "without replacement", "pity"]
	out.append("table: %d entries, %s" % [ids.size(), names[policy]])
	var w := _effective_weights()
	var total := 0.0
	for x in w:
		total += maxf(0.0, x)
	for i in range(ids.size()):
		var pct := (maxf(0.0, w[i]) / total * 100.0) if total > 0.0 else 0.0
		out.append(
			"  %-20s %7.2f  %5.2f%%%s"
			% [
				String(ids[i]),
				w[i],
				pct,
				("  (+%.2f pity)" % _pity[i]) if i < _pity.size() and _pity[i] > 0.0 else "",
			]
		)
	if policy == Policy.WITHOUT_REPLACEMENT:
		out.append("  %d cards left in the deck" % deck_remaining())
	return out
