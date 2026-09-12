@tool
class_name DotRandomTable
extends Resource

## A weighted table of ids, with the three draw policies every shipped game ends up with.
##
## [b]It draws ids and knows nothing about what they are.[/b] Same rule as dot-loadout's
## "sells ids and grants nothing" and dot-economy's shop: a table of loot validates and
## draws on a server that does not have the content, and the id is resolved by whoever
## asked.
##
## The three policies exist because flat weighted sampling is wrong for most of what
## people actually use a loot table for:
##
## [b]WITH_REPLACEMENT[/b] is the honest one. Every draw is independent. It is also the
## one that makes a player who has opened forty crates and seen no rare drop conclude the
## game is broken — which is not superstition, it is what a 2% chance feels like.
##
## [b]WITHOUT_REPLACEMENT[/b] is a deck: shuffled once, dealt, reshuffled when empty. The
## variance is gone, which is what a rotation, a map vote's nominations and a card game
## want. It is [i]not[/i] what a loot table wants, because a player can count the deck.
##
## [b]PITY[/b] is what almost every game with a rare drop actually ships and almost
## nobody documents: the weight of an entry climbs every time it is missed and resets when
## it lands, so the forty-crate story stops happening.
##
## [b]Set [member pity_after] or the base weight stops meaning anything.[/b] Measured
## here: a 2% entry with a ramp starting on the first miss comes out at 14.5%, because
## most droughts are short and the ramp was already inflating all of them. Starting the
## ramp past the stated mean interval leaves the ordinary case untouched and cuts only the
## tail — and even then the realised rate sits a little above the base, because removing
## the long tail of a distribution and changing nothing else must raise its mean.
## [method measure_rate] is the only honest way to know by how much.
##
## [codeblock]
## var t := DotRandomTable.new()
## t.policy = DotRandomTable.Policy.PITY
## t.pity_after = 60             # ~2% means ~50 draws; leave the usual case alone
## t.add(&"common", 98.0)
## t.add(&"rare", 2.0, 4.0)      # +4 weight per miss, once past the ramp
## t.draw(stream)
## [/codeblock]

enum Policy {
	## Independent draws. The default, and the only one with no memory.
	WITH_REPLACEMENT,
	## A shuffled deck, reshuffled when exhausted.
	WITHOUT_REPLACEMENT,
	## Weights climb on a miss and reset on a hit.
	PITY,
}

## An entry's id, weight and pity step, flattened into parallel arrays.
##
## Flattened rather than an [code]Array[Resource][/code] because a table is content: it
## round-trips through JSON in a catalogue, it is compared for equality between a server
## and a client, and a nested resource is the shape that quietly becomes a shared
## reference. [method to_dictionary] duplicates on the way out for the same reason —
## [code]DotLeaderboardDef.scoped()[/code] handed out its own dictionary and every board
## on the server ended up sharing one.
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
##
## Uncapped pity turns into a guarantee, and a guarantee is a different design: players
## learn the exact count and open crates in batches up to it.
@export_range(0.0, 100000.0, 0.1, "or_greater") var pity_cap: float = 1000.0

## How many consecutive misses an entry takes before its weight starts climbing.
##
## [b]This is the setting that keeps the number on the tin true, and leaving it at zero
## is a measured 2% entry coming out at 14.5%.[/b] Pity that starts immediately is
## climbing on the very first draw, so the base weight stops describing anything: the
## early draws — which are most draws, because most droughts are short — are already
## inflated.
##
## Set past the stated mean interval (1/p) and the ordinary case is untouched: a player
## who gets their drop in the usual twenty draws never reaches the ramp at all, and only
## the unlucky tail is cut.
##
## [b]It cannot be free.[/b] Removing the long tail of a distribution and leaving
## everything else alone necessarily raises the mean rate — that is arithmetic, not a bug
## — so the realised rate is always a little above the base weight.
## [method measure_rate] is how you find out by how much, and the number to tune against.
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
##
## Called at boot rather than at the first draw on purpose: a malformed loot table should
## fail a server's start-up, not produce an empty drop at the moment a player kills
## something.
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
##
## Filtering here rather than by building a second table matters for pity: two tables
## over the same entries have two pity counters, and a player who draws from both sees
## the rare entry at twice the stated rate.
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
##
## Weights are honoured by putting an entry into the deck more than once, rounded to the
## nearest whole card with a floor of one — so a weight of 0.4 against a weight of 2.0 is
## one card against two, rather than being silently dropped. A table whose weights are
## all fractions is a table somebody meant as probabilities, and dealing it as an empty
## deck would be the most confusing possible answer.
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


## The rate [param id] actually comes out at, and the longest drought seen, over
## [param samples] draws.
##
## [b]A pity table's base weight is not its rate, and this is the only honest way to know
## what it is.[/b] The two numbers are the design: the rate is what a player is told and
## the drought is what they feel. Tuning one without measuring the other is how a table
## ends up at seven times its advertised rate with nobody noticing, because every draw
## looked plausible.
##
## Returns [code]{"rate": float, "longest_drought": int, "hits": int}[/code]. It runs on
## a copy, so a live table's counters are not disturbed by being measured.
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
##
## [b]Not [code]reset_state[/code], which is the name it was written with and is the name
## of a method [Resource] already has.[/b] GDScript accepts the definition without a
## warning, the file parses clean, and every call binds to the ENGINE's method -- so this
## ran on every call and did nothing at all, with the deck and every pity counter intact
## afterwards. A table reset between rounds kept the previous round's drought, and the
## only symptom is a rare drop arriving sooner than it should. Nothing in this family had
## shadowed a native method before; the detector is a grep for the ones [Object] and
## [Resource] already define.
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
##
## Duplicated on the way out. A [Dictionary] and a packed array are both references in
## GDScript, and this family has shipped that aliasing four times — a scoped leaderboard
## sharing its template's dictionary, a zone payload, three of a record's dictionaries
## and a map's metadata.
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
##
## They are written beside each other for the reason this family keeps relearning: a
## stored voice mute came back as a warning because [code]to_dictionary[/code] wrote the
## player-facing name and the reader had no case for it, and nothing errored.
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
