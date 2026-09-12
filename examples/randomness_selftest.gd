extends Node

## Exercises dot-randomness with no world, no transport and no scene.
##
## [b]Every check here is about a distribution or about agreement, never about one
## particular number.[/b] Asserting that draw 4,192 is 0.31 asserts the mixer, which
## nobody is going to change and which tells you nothing when it fails. What this family
## has actually been bitten by is the other kind: a hash that returned only the bottom
## half of its range, and every shotgun pattern a half-moon while a maximum-magnitude
## assertion passed throughout. So the uniformity checks count quadrants and buckets.
##
## [codeblock]
## godot --headless --path . res://examples/randomness_selftest.tscn
## [/codeblock]

## [b]CHECKS is the guard the section counter cannot be.[/b] A script error inside a test
## aborts THAT TEST, not the run — and this suite proved it: a mismatched-type comparison
## in one section took eight checks out of a run that reported "0 failed" and exited 0.
## The section counter did not fire, because the section had already announced itself.
## A total does fire, and it is one line.
const SECTIONS := 9
const CHECKS := 90

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-randomness self-test")
	_line("")

	_test_determinism()
	_test_uniformity()
	_test_independence()
	_test_indexed_purity()
	_test_collections()
	_test_geometry()
	_test_tables()
	_test_schedules()
	_test_manager()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if CHECKS > 0 and _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- 1 ----------------------------------------------------------------------

func _test_determinism() -> void:
	_section("A seed is the whole state")

	var a := DotRandomStream.new(12345, &"world")
	var b := DotRandomStream.new(12345, &"world")
	var same := true
	for _i in range(500):
		if a.next() != b.next():
			same = false
			break
	_check(same, "two streams from one seed and one name agree for 500 draws")

	var c := DotRandomStream.new(12346, &"world")
	var d := DotRandomStream.new(12345, &"other")
	_check(
		DotRandomStream.new(12345, &"world").at(0) != c.at(0),
		"a different seed is a different stream"
	)
	_check(
		DotRandomStream.new(12345, &"world").at(0) != d.at(0),
		"and so is a different name on the same seed"
	)

	var s := DotRandomStream.new(99, &"resume")
	for _i in range(37):
		s.next()
	var mid := s.state()
	var expected := s.next()

	var t := DotRandomStream.new()
	var res := t.adopt(mid)
	_check(res.ok, "a state adopts")
	_check(t.next() == expected, "and continues exactly where the original was")

	var bad := DotRandomStream.new().adopt({"counter": 4})
	_check(not bad.ok, "a state with no key is refused")
	_check(bad.code() == DotError.CODE_INVALID, "with CODE_INVALID")

	# The gaussian spare is part of the state, and leaving it out is a drift of one
	# sample somewhere in the middle of a replay -- which is exactly the kind of bug
	# that reports as "the replay diverges near the end".
	var g := DotRandomStream.new(7, &"gauss")
	g.next_gaussian()
	var g_mid := g.state()
	var g_expected := g.next_gaussian()
	var g2 := DotRandomStream.new()
	g2.adopt(g_mid)
	_check(
		is_equal_approx(g2.next_gaussian(), g_expected),
		"and the Box-Muller spare travels with it"
	)


# --- 2 ----------------------------------------------------------------------

func _test_uniformity() -> void:
	_section("The range is the whole range")

	var s := DotRandomStream.new(4242, &"unit")
	var buckets := PackedInt32Array()
	buckets.resize(10)
	var lo := INF
	var hi := -INF
	var above_half := 0
	const N := 20000
	for i in range(N):
		var u := s.unit_at(i)
		lo = minf(lo, u)
		hi = maxf(hi, u)
		if u >= 0.5:
			above_half += 1
		buckets[clampi(int(u * 10.0), 0, 9)] += 1

	_check(lo >= 0.0 and hi < 1.0, "unit() stays inside [0, 1)")
	# The half-moon check. `DotSpread.unit()` shipped with 23 bits where it wanted 24 and
	# never returned a value above 0.5; every maximum-magnitude assertion passed.
	_check(
		absf(float(above_half) / float(N) - 0.5) < 0.02,
		"and half of it is above 0.5, which a half-width hash is not"
	)

	var worst := 0.0
	for b in buckets:
		worst = maxf(worst, absf(float(b) / float(N) - 0.1))
	_check(worst < 0.01, "ten buckets are each within one point of a tenth")

	var counts := {}
	for i in range(6000):
		var v := s.range_i_at(i, 3, 8)
		counts[v] = int(counts.get(v, 0)) + 1
	_check(counts.size() == 6, "range_i covers every value of an inclusive range")
	_check(
		not counts.has(2) and not counts.has(9),
		"and never leaves it"
	)
	var flattest := 0
	var fullest := 0
	for k in counts.keys():
		var c: int = counts[k]
		flattest = c if flattest == 0 else mini(flattest, c)
		fullest = maxi(fullest, c)
	_check(float(fullest - flattest) / 1000.0 < 0.15, "and no value is favoured")

	var heads := 0
	for i in range(10000):
		if s.chance_at(i, 0.25):
			heads += 1
	_check(absf(float(heads) / 10000.0 - 0.25) < 0.02, "a 25% chance happens a quarter of the time")
	_check(not s.chance_at(1, 0.0) and s.chance_at(1, 1.0), "0 never and 1 always")


# --- 3 ----------------------------------------------------------------------

func _test_independence() -> void:
	_section("Drawing from one stream does not move another")

	var root := DotRandomStream.new(777, &"root")
	var loot := root.stream(&"loot")
	var spread := root.stream(&"spread")

	var expected: Array[float] = []
	for _i in range(5):
		expected.append(spread.next_unit())

	var root2 := DotRandomStream.new(777, &"root")
	var spread2 := root2.stream(&"spread")
	var loot2 := root2.stream(&"loot")
	# The whole point: a thousand loot draws in between, in a different order of
	# creation, and spread is untouched.
	for _i in range(1000):
		loot2.next()
	var agreed := true
	for i in range(5):
		if not is_equal_approx(spread2.next_unit(), expected[i]):
			agreed = false
	_check(agreed, "1000 draws from a sibling stream leave this one exactly where it was")
	_check(loot.at(0) != spread.at(0), "and siblings are not each other")

	var per_player_a := root.stream_for(&"crit", 4001)
	var per_player_b := root.stream_for(&"crit", 4002)
	_check(per_player_a.at(0) != per_player_b.at(0), "two subjects under one name differ")
	_check(
		root.stream_for(&"crit", 4001).at(0) == per_player_a.at(0),
		"and the same subject is the same stream"
	)


# --- 4 ----------------------------------------------------------------------

func _test_indexed_purity() -> void:
	_section("An indexed draw advances nothing")

	var s := DotRandomStream.new(31337, &"pure")
	var before := s.counter()
	var a := s.unit_at(900)
	var b := s.unit_at(900)
	_check(s.counter() == before, "at() leaves the counter alone")
	_check(is_equal_approx(a, b), "and answers the same thing twice")

	var forward := s.unit_at(5)
	s.set_counter(5)
	_check(is_equal_approx(s.next_unit(), forward), "next() is at() at the counter")
	_check(s.counter() == 6, "and then moves it")

	# The dot-2d lesson: a receiving peer adopts an index rather than allocating one.
	var mirror := DotRandomStream.new()
	mirror.adopt(s.state())
	_check(
		is_equal_approx(mirror.unit_at(12345), s.unit_at(12345)),
		"a mirrored stream answers for a tick it never simulated"
	)


# --- 5 ----------------------------------------------------------------------

func _test_collections() -> void:
	_section("Shuffles, samples and weights")

	var s := DotRandomStream.new(5150, &"coll")
	var source := [1, 2, 3, 4, 5, 6, 7, 8]
	var shuffled := s.next_shuffled(source)
	_check(source == [1, 2, 3, 4, 5, 6, 7, 8], "a shuffle does not touch the original")
	_check(shuffled.size() == source.size(), "and keeps every element")
	var kept := true
	for v in source:
		if not shuffled.has(v):
			kept = false
	_check(kept, "exactly once each")

	# Fisher-Yates upward is not uniform, and the way you see it is by counting where one
	# element lands rather than by looking at one shuffle.
	var landed := PackedInt32Array()
	landed.resize(8)
	for _i in range(8000):
		landed[s.next_shuffled(source).find(1)] += 1
	var worst := 0.0
	for c in landed:
		worst = maxf(worst, absf(float(c) / 8000.0 - 0.125))
	_check(worst < 0.015, "and one element lands in every position equally often")

	var sample := s.next_sample(source, 3)
	_check(sample.size() == 3, "a sample is the size asked for")
	_check(
		sample[0] != sample[1] and sample[1] != sample[2] and sample[0] != sample[2],
		"with no repeats"
	)
	_check(s.next_sample(source, 99).size() == source.size(), "and is capped at what there is")

	var weights := PackedFloat32Array([0.0, 3.0, 1.0])
	var picks := PackedInt32Array()
	picks.resize(3)
	for _i in range(4000):
		picks[s.next_weighted(weights)] += 1
	_check(picks[0] == 0, "a weight of zero is never drawn")
	_check(
		absf(float(picks[1]) / 4000.0 - 0.75) < 0.03,
		"and three-to-one comes out three to one"
	)
	_check(s.next_weighted(PackedFloat32Array([0.0, 0.0])) == -1, "all-zero weights answer -1")


# --- 6 ----------------------------------------------------------------------

	# `next_pick` and `next_sign` were public and called by nothing. Both are asserted on
	# their DISTRIBUTION rather than on one draw: a picker that always returns the first
	# element and a sign that is always 1 both pass any single-call check.
	var pick_stream := DotRandomStream.new(99)
	var seen := {}
	for _i in range(300):
		seen[pick_stream.next_pick([&"a", &"b", &"c"])] = true
	_check(seen.size() == 3, "a pick reaches every element, not just the first")
	_check(pick_stream.next_pick([]) == null, "and an empty array picks nothing rather than erroring")

	var signs := {-1: 0, 1: 0}
	for _i in range(400):
		signs[pick_stream.next_sign()] += 1
	_check(
		signs[-1] > 150 and signs[1] > 150,
		"a sign is both signs, near evenly (%d down, %d up)" % [signs[-1], signs[1]]
	)


func _test_geometry() -> void:
	_section("Points and directions are uniform by area")

	var s := DotRandomStream.new(2718, &"geom")

	# The quadrant check, which is the one that catches a half-range hash. A
	# maximum-magnitude check passes for a half-moon; this does not.
	var quads := PackedInt32Array()
	quads.resize(4)
	var longest := 0.0
	for _i in range(8000):
		var p := s.next_point_in_circle(2.0)
		longest = maxf(longest, p.length())
		var q := (0 if p.x >= 0.0 else 1) + (0 if p.y >= 0.0 else 2)
		quads[q] += 1
	_check(longest <= 2.0001, "a point in a circle stays inside the radius")
	var worst := 0.0
	for c in quads:
		worst = maxf(worst, absf(float(c) / 8000.0 - 0.25))
	_check(worst < 0.02, "and all four quadrants get a quarter of the points")

	# Uniform by area means the inner half of the radius holds a quarter of the points.
	# Drawing the radius flat instead puts half of them there, which looks like a target.
	var inner := 0
	for _i in range(8000):
		if s.next_point_in_circle(1.0).length() < 0.5:
			inner += 1
	_check(
		absf(float(inner) / 8000.0 - 0.25) < 0.02,
		"and the inner half-radius holds a quarter of them, not half"
	)

	var bands := PackedInt32Array()
	bands.resize(4)
	var unit_ok := true
	for _i in range(8000):
		var d := s.next_direction_3d()
		if absf(d.length() - 1.0) > 0.0001:
			unit_ok = false
		bands[clampi(int((d.z + 1.0) * 2.0), 0, 3)] += 1
	_check(unit_ok, "a 3D direction is a unit vector")
	worst = 0.0
	for c in bands:
		worst = maxf(worst, absf(float(c) / 8000.0 - 0.25))
	_check(worst < 0.02, "and equal bands of z hold equal numbers, so it does not cluster at the poles")

	var axis := Vector3(0, 0, -1)
	var outside := 0
	for _i in range(2000):
		if rad_to_deg(acos(clampf(s.next_cone(axis, 15.0).dot(axis), -1.0, 1.0))) > 15.001:
			outside += 1
	_check(outside == 0, "a cone never leaves its angle")


# --- 7 ----------------------------------------------------------------------

func _test_tables() -> void:
	_section("Tables: replacement, decks and pity")

	var s := DotRandomStream.new(808, &"table")

	var flat := DotRandomTable.new()
	flat.add(&"common", 90.0).add(&"rare", 10.0)
	_check(flat.validate().ok, "a well-formed table validates")

	var dupe := DotRandomTable.new()
	dupe.add(&"x", 1.0).add(&"x", 1.0)
	_check(not dupe.validate().ok, "a duplicate id is refused, because pity cannot tell them apart")
	var empty := DotRandomTable.new()
	_check(not empty.validate().ok, "and so is a table with nothing in it")

	var hits := 0
	for _i in range(4000):
		if flat.draw(s) == &"rare":
			hits += 1
	_check(absf(float(hits) / 4000.0 - 0.1) < 0.02, "flat weights come out flat")

	var deck := DotRandomTable.new()
	deck.policy = DotRandomTable.Policy.WITHOUT_REPLACEMENT
	deck.add(&"a", 1.0).add(&"b", 1.0).add(&"c", 1.0)
	var dealt := deck.draw_many(s, 3)
	_check(
		dealt.has(&"a") and dealt.has(&"b") and dealt.has(&"c"),
		"a deck deals every card before repeating one"
	)
	_check(deck.deck_remaining() == 0, "and knows it is empty")
	deck.draw(s)
	_check(deck.deck_remaining() == 2, "and reshuffles itself")

	# Pity is the whole reason this class is not four lines, and it has to be measured
	# in two dimensions at once. A check on the drought alone passes for a table running
	# at seven times its advertised rate; a check on the rate alone passes for a table
	# that still makes one player in fifty wait for ever.
	var eager := DotRandomTable.new()
	eager.policy = DotRandomTable.Policy.PITY
	eager.add(&"common", 98.0).add(&"rare", 2.0, 4.0)
	var eager_m := eager.measure_rate(s, &"rare", 20000)
	_check(
		float(eager_m["rate"]) > 0.05,
		"pity starting on the first miss wrecks the base weight: 2%% measures %.1f%%"
		% (float(eager_m["rate"]) * 100.0)
	)

	var pity := DotRandomTable.new()
	pity.policy = DotRandomTable.Policy.PITY
	pity.pity_after = 60
	pity.add(&"common", 98.0).add(&"rare", 2.0, 4.0)
	var m := pity.measure_rate(s, &"rare", 40000)
	var rate := float(m["rate"])
	var longest: int = m["longest_drought"]
	_check(int(m["hits"]) > 0, "pity draws the rare entry")
	_check(longest < 120, "and cuts the tail off: the longest drought was %d" % longest)
	_check(
		rate > 0.02 and rate < 0.035,
		"while the rate stays near the one on the tin (%.3f against 0.020)" % rate
	)
	_check(
		pity.measure_rate(s, &"rare", 2000)["hits"] == pity.measure_rate(s, &"rare", 2000)["hits"],
		"and measuring is repeatable, because it runs on a copy of both the table and the stream"
	)
	_check(pity.pity_of(&"common") == 0.0, "an entry with no pity step never accumulates one")
	for _i in range(30):
		pity.draw(s)
	_check(pity.pity_of(&"rare") == 0.0, "and nothing accumulates inside pity_after")

	# `misses_of`, `draw_tagged` and `reset_state` were public, documented and called by
	# nothing -- the family's most repeated bug, which is why the detector is run over
	# methods as well as over settings.
	var missed := pity.misses_of(&"rare")
	_check(missed > 0, "a run of misses is counted (%d)" % missed)
	_check(pity.misses_of(&"nothing_like_this") == 0, "and something not in the table has none")

	# `forget_state` was written as `reset_state`, which is a method `Resource` already has
	# -- so it parsed, ran on every call, and did nothing. The check is on the DROUGHT
	# rather than on the pity weight, because at this point in the run the weight is
	# legitimately zero either way and would have passed with the bug in place.
	pity.forget_state()
	_check(pity.misses_of(&"rare") == 0, "resetting the state forgets the drought")
	_check(pity.pity_of(&"rare") == 0.0, "and the weight it had earned")
	_check(pity.size() == 2, "while the entries themselves are untouched")

	# The reason filtering happens inside the table rather than by building a second one:
	# two tables over the same entries have two pity counters, and a player drawing from
	# both sees the rare entry at twice the stated rate.
	var tagged := DotRandomTable.new()
	tagged.add(&"sword", 1.0, 0.0, &"weapon")
	tagged.add(&"shield", 1.0, 0.0, &"armour")
	tagged.add(&"axe", 1.0, 0.0, &"weapon")
	var weapons := {}
	for _i in range(200):
		weapons[tagged.draw_tagged(s, &"weapon")] = true
	_check(
		weapons.size() == 2 and weapons.has(&"sword") and weapons.has(&"axe"),
		"a tagged draw returns only what carries the tag"
	)
	_check(
		tagged.draw_tagged(s, &"no_such_tag") == &"",
		"and a tag nothing carries draws nothing, rather than falling back to the whole table"
	)

	var round_trip := DotRandomTable.from_dictionary(pity.to_dictionary())
	_check(round_trip.size() == pity.size(), "a table round-trips through a dictionary")
	_check(round_trip.policy == pity.policy, "with its policy")
	_check(
		is_equal_approx(round_trip.weights[1], pity.weights[1]),
		"and its weights"
	)
	_check(round_trip.pity_after == pity.pity_after, "and the setting that makes pity honest")
	# The two ends of a serialisation are exactly as capable of never meeting as the two
	# ends of a wire: a stored voice mute in this family came back as a warning.
	var d := pity.to_dictionary()
	d["weights"][0] = 1.0
	_check(
		not is_equal_approx(pity.weights[0], 1.0),
		"and the dictionary it hands out is a copy, not its own state"
	)


# --- 8 ----------------------------------------------------------------------

func _test_schedules() -> void:
	_section("Events in ticks, decided without simulating")

	var s := DotRandomStream.new(64000, &"sched")

	var sched := DotRandomSchedule.new()
	sched.mean_interval_ticks = 640
	sched.min_gap_ticks = 128
	_check(sched.validate().ok, "a sane schedule validates")

	var never := DotRandomSchedule.new()
	never.mean_interval_ticks = 100
	never.min_gap_ticks = 100
	_check(not never.validate().ok, "a floor at the mean is a metronome and is refused")

	var fired := false
	for t in range(0, 128):
		if sched.fires_at(s, t, 0):
			fired = true
	_check(not fired, "nothing fires inside the minimum gap")

	var mean := sched.measure_mean_interval(s, 300)
	_check(
		absf(mean - 640.0) / 640.0 < 0.12,
		"and the measured mean is the mean asked for (%.0f against 640)" % mean
	)

	# Purity: the same tick answers the same way whatever order it is asked in, which is
	# what lets a client know what the server will do.
	var forward: Array[bool] = []
	for t in range(2000, 2100):
		forward.append(sched.fires_at(s, t, 1900))
	var backward := true
	for i in range(99, -1, -1):
		if sched.fires_at(s, 2000 + i, 1900) != forward[i]:
			backward = false
	_check(backward, "and a tick answers the same asked backwards")

	var ceiling := DotRandomSchedule.new()
	ceiling.mean_interval_ticks = 100000
	ceiling.min_gap_ticks = 10
	ceiling.max_gap_ticks = 200
	_check(ceiling.fires_at(s, 200, 0), "a ceiling fires however improbable the roll")
	_check(not ceiling.fires_at(s, 5, 0), "and the floor still wins under it")

	var off := DotRandomSchedule.new()
	off.mean_interval_ticks = 0
	_check(not off.fires_at(s, 999999, 0), "a mean of zero never fires")
	# Zero means "never" here and "every tick" in some of this family's other settings.
	# It is written down at both ends because two settings named the same way meaning
	# opposite things at zero is the kind of difference nobody reads twice.
	_check(off.next_fire(s, 0, 0, 500) == -1, "and next_fire says so rather than looping")


# --- 9 ----------------------------------------------------------------------

func _test_manager() -> void:
	_section("The manager a game holds")

	var m := DotRandomManager.new()
	m.config = DotRandomConfig.new()
	m.config.master_seed = 4096
	m.config.announce_seed = false
	add_child(m)
	var res := m.setup()
	_check(res.ok, "the manager sets up")
	_check(m.current_seed() == 4096, "and keeps the configured seed")
	_check(DotRegistry.has(DotRandomManager.SERVICE), "and publishes itself in the registry")

	var a := m.stream(&"loot")
	var b := m.stream(&"loot")
	_check(a == b, "one name is one stream, not two with the same numbers")
	_check(m.private_stream(&"loot") != a, "and a private stream is nobody else's")

	var before := a.next()
	var reseeds := []
	m.reseeded.connect(func(sd: int) -> void: reseeds.append(sd))
	m.reseed(9999)
	_check(reseeds.size() == 1 and reseeds[0] == 9999, "reseeding announces itself")
	_check(m.stream(&"loot").at(0) != before, "and gives a different world")
	_check(
		a.at(0) != m.stream(&"loot").at(0),
		"while a stream handed out earlier keeps the old one, which is why the signal exists"
	)

	var unseeded := DotRandomManager.new()
	unseeded.config = DotRandomConfig.new()
	unseeded.config.master_seed = 0
	unseeded.config.random_when_unseeded = false
	unseeded.config.announce_seed = false
	unseeded.register_as_service = false
	add_child(unseeded)
	unseeded.setup()
	_check(unseeded.current_seed() == 0, "an unseeded session can be made deterministic")

	_check(m.seed_for(&"world") != m.seed_for(&"other"), "derived seeds differ by name")
	_check(m.describe_lines().size() > 2, "and it describes itself")

	m.queue_free()
	unseeded.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
