extends Node

## Exercises [DotLoadGate] and [DotLoadingCover]: holds and releases, predicates, the
## timeout and its warning, freezing, settling frozen bodies under the cover, closing again, the camera requirement and its own
## warm-up, a host claiming the cover, and the older shells' root signal.
##
## [codeblock]
## godot --headless --path . res://examples/load_gate_selftest.tscn
## [/codeblock]

const SECTIONS := 9
const CHECKS := 76

var _passed := 0
var _failed := 0
var _section_count := 0
var _records: Array = []
var _sink := Callable()


class FakeHost:
	extends RefCounted
	var adopted: Array = []

	func adopt_load_gate(gate: Object) -> void:
		adopted.append(gate)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.DEBUG)
	DotLog.print_to_stdout = false
	_sink = _on_record
	DotLog.add_sink(_sink)
	_run()


func _on_record(rec: Dictionary) -> void:
	_records.append(rec)


# A sink left in DotLog's static list outlives this script, and the engine's exit teardown
# then frees memory twice (a heap abort after "0 failed").
func _exit_tree() -> void:
	DotLog.remove_sink(_sink)


func _run() -> void:
	_line("dot-core load gate self-test")
	_line("")

	await _test_hold_release()
	await _test_predicates()
	await _test_timeout()
	await _test_freeze()
	await _test_settle()
	await _test_reclose()
	await _test_camera_and_own_warmup()
	await _test_hosted()
	await _test_finding_and_old_shells()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		_line("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## A game root with a gate that needs no camera, so a test controls every reason itself.
func _make(no_camera := true) -> DotLoadGate:
	var root := Node.new()
	root.name = "Game%d" % _section_count
	add_child(root)
	var gate := DotLoadGate.new()
	gate.register_service = false
	gate.require_camera = not no_camera
	gate.warm_timeout_sec = 0.2
	root.add_child(gate)
	return gate


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
	await get_tree().process_frame


func _drop(gate: DotLoadGate) -> void:
	var root := gate.get_parent()
	remove_child(root)
	root.free()


func _test_hold_release() -> void:
	_section("holds and releases")
	var gate := _make()
	var said: Array = []
	gate.progress_changed.connect(func(f: float, t: String) -> void: said.append([f, t]))
	var opened: Array = []
	gate.opened.connect(func() -> void: opened.append(true))
	gate.hold(&"map", "Loading the map")
	gate.hold(&"players", "Waiting for players")
	_check(not gate.is_open() and gate.state() == DotLoadGate.State.CLOSED, "closed while something is held")
	_check(gate.status_text() == "Waiting for players", "the newest hold says what is happening", gate.status_text())
	_check(gate.reasons() == [&"map", &"players"], "reasons lists both, oldest first", str(gate.reasons()))
	_check(gate.is_cover_showing(), "with no host the gate's own cover is up")
	gate.set_progress(0.5, "Half way")
	_check(not said.is_empty() and said[-1] == [0.5, "Half way"], "set_progress is announced", str(said.back()))
	_check((gate.cover as DotLoadingCover).status() == "Half way", "and shown on the cover")
	gate.set_progress(-1.0)
	gate.release(&"players")
	_check(gate.status_text() == "Loading the map", "releasing one hands the line to the other", gate.status_text())
	await _frames(6)
	_check(not gate.is_open(), "still closed while one is held")
	gate.release(&"map")
	gate.release(&"never-held")
	await _frames(6)
	_check(gate.is_open() and opened.size() == 1, "open once nothing is held", str(gate.describe()))
	_check(not gate.is_cover_showing(), "and the cover is gone")
	_check(gate.describe_lines().size() == 4 and gate.describe_lines()[0].begins_with("load gate: OPEN"), "describe_lines", str(gate.describe_lines()))
	_drop(gate)


func _test_predicates() -> void:
	_section("requirements polled every frame")
	var gate := _make()
	var flag := [false]
	gate.require(&"level", func() -> bool: return flag[0], "Building the level")
	_check(gate.is_holding(&"level") and gate.status_text() == "Building the level", "a requirement holds and speaks")
	await _frames(5)
	_check(not gate.is_open(), "closed while it is false")
	flag[0] = true
	await _frames(6)
	_check(not gate.is_holding(&"level"), "dropped once true")
	_check(gate.is_open(), "and the gate opens")
	# A predicate whose object is gone counts as met, rather than holding for ever.
	var gate2 := _make()
	var owner_node := Node.new()
	gate2.require(&"gone", Callable(owner_node, &"is_inside_tree"))
	owner_node.free()
	await _frames(6)
	_check(gate2.is_open(), "a predicate on a freed object counts as met")
	_drop(gate)
	_drop(gate2)


func _test_timeout() -> void:
	_section("the timeout opens it with a warning")
	var gate := _make()
	gate.timeout_sec = 0.3
	gate.hold(&"map", "Loading the map")
	gate.require(&"never", func() -> bool: return false)
	_records.clear()
	var t0 := Time.get_ticks_msec()
	while not gate.is_open() and Time.get_ticks_msec() - t0 < 3000:
		await get_tree().process_frame
	_check(gate.is_open(), "open after the timeout")
	var warned: Array = _records.filter(func(r: Dictionary) -> bool:
		return int(r["level"]) == DotLog.Level.WARN and r["channel"] == DotLoadGate.CHANNEL)
	_check(warned.size() == 1, "exactly one warning", str(warned.size()))
	var held: Array = (warned[0]["fields"] as Dictionary).get("still_held", []) if warned.size() > 0 else []
	_check(held.has("map") and held.has("never"), "naming every reason still held", str(held))
	_check(gate.reasons().is_empty(), "and nothing is held afterwards")
	var infos: Array = _records.filter(func(r: Dictionary) -> bool:
		return int(r["level"]) == DotLog.Level.INFO and r["channel"] == DotLoadGate.CHANNEL)
	_check(infos.size() == 1 and (infos[0]["fields"]["timed_out"] as Array).size() == 2, "the open line says it timed out", str(infos))
	_drop(gate)


func _test_freeze() -> void:
	_section("freezing and restoring process_mode")
	var gate := _make()
	var body := Node3D.new()
	body.process_mode = Node.PROCESS_MODE_PAUSABLE
	var other := Node.new()
	other.process_mode = Node.PROCESS_MODE_ALWAYS
	gate.get_parent().add_child(body)
	gate.get_parent().add_child(other)
	gate.hold(&"map")
	gate.freeze(body)
	gate.freeze(other)
	gate.freeze(body)  # twice is once
	_check(body.process_mode == Node.PROCESS_MODE_DISABLED and other.process_mode == Node.PROCESS_MODE_DISABLED, "frozen while closed")
	_check(int(gate.describe()["frozen"]) == 2, "counted once each", str(gate.describe()))
	gate.release(&"map")
	await _frames(6)
	_check(gate.is_open(), "open")
	_check(body.process_mode == Node.PROCESS_MODE_PAUSABLE and other.process_mode == Node.PROCESS_MODE_ALWAYS, "each gets its own mode back")
	var late := Node.new()
	late.process_mode = Node.PROCESS_MODE_INHERIT
	gate.get_parent().add_child(late)
	gate.freeze(late)
	_check(late.process_mode == Node.PROCESS_MODE_INHERIT, "a node frozen while open is only remembered")
	gate.hold(&"map2")
	_check(body.process_mode == Node.PROCESS_MODE_DISABLED and late.process_mode == Node.PROCESS_MODE_DISABLED, "closing again freezes every remembered node")
	other.free()
	gate.unfreeze(late)
	_check(late.process_mode == Node.PROCESS_MODE_INHERIT, "unfreeze restores at once")
	gate.release(&"map2")
	await _frames(6)
	_check(body.process_mode == Node.PROCESS_MODE_PAUSABLE and int(gate.describe()["watched"]) == 1, "a freed node and an unfrozen one are forgotten", str(gate.describe()))
	gate.hold(&"x")
	var root := gate.get_parent()
	root.remove_child(gate)
	_check(body.process_mode == Node.PROCESS_MODE_PAUSABLE, "a gate leaving the tree never leaves a body frozen")
	gate.free()
	remove_child(root)
	root.free()


## A body frozen in the air, over a floor.
func _settle_rig(gate: DotLoadGate) -> Array:
	var root := gate.get_parent()
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 20)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	var body: CharacterBody3D = (load("res://examples/load_gate_settle_body.gd") as GDScript).new()
	var shape := CollisionShape3D.new()
	var cube := BoxShape3D.new()
	cube.size = Vector3.ONE
	shape.shape = cube
	body.add_child(shape)
	body.position = Vector3(0, 1.0, 0)  # bottom 0.4 m above the floor's top
	root.add_child(body)
	var sampler := Node.new()
	sampler.process_mode = Node.PROCESS_MODE_PAUSABLE
	root.add_child(sampler)
	return [body, sampler]


func _test_settle() -> void:
	_section("frozen bodies settle under the cover, input off")
	var gate := _make()
	var rig := _settle_rig(gate)
	var body: CharacterBody3D = rig[0]
	var sampler: Node = rig[1]
	var at_open: Array = []
	gate.opened.connect(func() -> void: at_open.append([body.is_on_floor(), body.position.y, body.input_enabled]))
	gate.hold(&"map")
	gate.freeze(body)
	gate.freeze_input(sampler)
	await _frames(4)
	_check(body.process_mode == Node.PROCESS_MODE_DISABLED and body.ticks == 0, "frozen while held: no tick at all")
	_records.clear()
	gate.release(&"map")
	var t0 := Time.get_ticks_msec()
	while not gate.is_settling() and not gate.is_open() and Time.get_ticks_msec() - t0 < 2000:
		await get_tree().physics_frame
	_check(gate.is_settling() and not gate.is_open(), "released: it settles before it opens", str(gate.describe()))
	_check(gate.is_cover_showing() and gate.state() == DotLoadGate.State.CLOSED, "still covered and still CLOSED to anyone asking")
	await _frames(3)
	_check(body.ticks > 0 and body.position.y < 1.0, "the frozen body simulates: it is falling", "ticks %d y %.3f" % [body.ticks, body.position.y])
	_check(not body.input_enabled and body.input_ticks == 0, "with its input_enabled off", "input ticks %d" % body.input_ticks)
	_check(not body.is_processing_unhandled_input() and body.has_meta(DotLoadGate.SETTLING_META), "its input events off and the settling meta on")
	var ev := InputEventKey.new()
	ev.keycode = KEY_W
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(1)
	_check(body.events == 0, "a key pressed while settling never reaches it", str(body.events))
	_check(sampler.process_mode == Node.PROCESS_MODE_DISABLED, "a freeze_input node stays stopped through settling")
	var input_seen := false
	t0 = Time.get_ticks_msec()
	while not gate.is_open() and Time.get_ticks_msec() - t0 < 3000:
		input_seen = input_seen or body.input_enabled
		await get_tree().physics_frame
	_check(gate.is_open() and at_open.size() == 1 and bool(at_open[0][0]), "it opens with the body on the floor", str(at_open))
	_check(not input_seen and body.input_ticks == 0, "input stayed off for every frame until then", "input ticks %d" % body.input_ticks)
	_check(body.input_enabled and body.is_processing_unhandled_input() and not body.has_meta(DotLoadGate.SETTLING_META), "is given back once open")
	_check(sampler.process_mode == Node.PROCESS_MODE_PAUSABLE, "and the freeze_input node gets its own mode back")
	var settled: Array = _records.filter(func(r: Dictionary) -> bool: return r["message"] == "settled")
	_check(settled.size() == 1 and bool(settled[0]["fields"]["at_rest"]) and int(settled[0]["fields"]["frames"]) < gate.settle_frames,
		"ended early, at rest, under the cap", str(settled))
	# A map change: frozen again, put back in the air, settles again.
	gate.hold(&"map2")
	_check(body.process_mode == Node.PROCESS_MODE_DISABLED and not gate.is_settling(), "a map change freezes it again")
	body.position = Vector3(0, 1.0, 0)
	body.velocity = Vector3.ZERO
	gate.release(&"map2")
	var seen_settling := false
	t0 = Time.get_ticks_msec()
	while not gate.is_open() and Time.get_ticks_msec() - t0 < 3000:
		seen_settling = seen_settling or gate.is_settling()
		await get_tree().physics_frame
	_check(seen_settling and gate.is_open() and at_open.size() == 2 and bool(at_open[1][0]), "and settles again before reopening", str(at_open))
	# Held again while settling: stopped again, and the next release settles afresh.
	body.position = Vector3(0, 1.0, 0)
	gate.hold(&"map3")
	gate.release(&"map3")
	t0 = Time.get_ticks_msec()
	while not gate.is_settling() and Time.get_ticks_msec() - t0 < 2000:
		await get_tree().physics_frame
	gate.hold(&"map4")
	_check(not gate.is_settling() and body.process_mode == Node.PROCESS_MODE_DISABLED and not body.input_enabled, "a hold while settling stops it again, input still off")
	gate.release(&"map4")
	t0 = Time.get_ticks_msec()
	while not gate.is_open() and Time.get_ticks_msec() - t0 < 3000:
		await get_tree().physics_frame
	_check(gate.is_open() and body.input_enabled, "and it opens after settling afresh")
	_drop(gate)
	# settle_frames 0: the old behaviour, frozen until open.
	var gate2 := _make()
	gate2.settle_frames = 0
	var rig2 := _settle_rig(gate2)
	var body2: CharacterBody3D = rig2[0]
	var mode_at_open: Array = []
	gate2.opened.connect(func() -> void: mode_at_open.append(body2.ticks))
	gate2.freeze(body2)
	t0 = Time.get_ticks_msec()
	var settling2 := false
	while not gate2.is_open() and Time.get_ticks_msec() - t0 < 2000:
		settling2 = settling2 or gate2.is_settling()
		await get_tree().physics_frame
	_check(gate2.is_open() and not settling2 and mode_at_open == [0], "settle_frames 0 skips it: frozen until open", str(mode_at_open))
	_drop(gate2)


func _test_reclose() -> void:
	_section("a second hold closes it again")
	var gate := _make()
	var log: Array = []
	gate.opened.connect(func() -> void: log.append("opened"))
	gate.closed.connect(func() -> void: log.append("closed"))
	gate.ready_to_show.connect(func() -> void: log.append("ready"))
	await _frames(6)
	_check(gate.is_open() and log == ["ready", "opened"], "nothing held: ready, then open", str(log))
	gate.hold(&"map", "Changing map")
	_check(not gate.is_open() and log.back() == "closed", "a hold while open closes it and says so", str(log))
	_check(gate.is_cover_showing() and (gate.cover as DotLoadingCover).status() == "Changing map", "and the cover is back with the new line")
	gate.release(&"map")
	await _frames(6)
	_check(log == ["ready", "opened", "closed", "ready", "opened"], "and it opens again", str(log))
	gate.hold(&"a")
	gate.hold(&"a")
	_check(log.count("closed") == 2, "holding twice closes once")
	_drop(gate)


func _test_camera_and_own_warmup() -> void:
	_section("a camera inside the game, and the gate's own warm-up")
	var gate := _make(false)
	gate.warm_up([StandardMaterial3D.new(), null])
	_check(gate.warm_items().size() == 1, "warm_up keeps items and drops nulls")
	await _frames(8)
	_check(not gate.is_open() and gate.is_holding(DotLoadGate.REASON_CAMERA), "no camera in the game: held")
	var elsewhere := Camera3D.new()
	add_child(elsewhere)
	elsewhere.make_current()
	await _frames(6)
	_check(not gate.is_open(), "a camera outside the game does not count")
	var cam := Camera3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	gate.get_parent().add_child(mesh)
	gate.get_parent().add_child(cam)
	cam.make_current()
	_check(gate.collect_warm_items().size() >= 2, "collect_warm_items has the tree's mesh and the extra", str(gate.collect_warm_items().size()))
	var t0 := Time.get_ticks_msec()
	var saw_warming := [false]
	gate.ready_to_show.connect(func() -> void: saw_warming[0] = gate.state() == DotLoadGate.State.WARMING)
	while not gate.is_open() and Time.get_ticks_msec() - t0 < 3000:
		await get_tree().process_frame
	_check(gate.is_open() and saw_warming[0], "a camera in the game opens it, through a warm-up", str(gate.describe()))
	await get_tree().process_frame
	_check(not cam.has_node("LoadGateWarmup"), "the warm-up is gone from the camera")
	remove_child(elsewhere)
	elsewhere.free()
	_drop(gate)


func _test_hosted() -> void:
	_section("a host claims the cover")
	var host := FakeHost.new()
	var root := Node.new()
	root.name = "HostedGame"
	add_child(root)
	set_meta(DotLoadGate.HOST_META, host)
	var gate := DotLoadGate.new()
	gate.register_service = false
	gate.require_camera = false
	gate.host_wait_sec = 0.4
	root.add_child(gate)
	remove_meta(DotLoadGate.HOST_META)
	_check(host.adopted == [gate], "the host's adopt_load_gate is called on entering the tree")
	_check(gate.is_hosted() and not gate.is_cover_showing(), "and the gate shows no cover of its own")
	var ready := [0]
	gate.ready_to_show.connect(func() -> void: ready[0] += 1)
	await _frames(6)
	_check(ready[0] == 1 and gate.state() == DotLoadGate.State.WARMING, "nothing held: it waits for the host's warm-up", str(gate.describe()))
	gate.host_finished()
	_check(gate.is_open(), "host_finished opens it")
	gate.hold(&"map")
	_check(not gate.is_cover_showing(), "closing again still shows nothing of its own")
	gate.release(&"map")
	await _frames(6)
	_records.clear()
	var t0 := Time.get_ticks_msec()
	while not gate.is_open() and Time.get_ticks_msec() - t0 < 3000:
		await get_tree().process_frame
	_check(gate.is_open(), "a host that never finishes is not waited on for ever")
	_check(_records.any(func(r: Dictionary) -> bool: return int(r["level"]) == DotLog.Level.WARN), "and that is a warning")
	# Claimed later, by a host that found the gate itself.
	var gate2 := _make()
	_check(gate2.is_cover_showing(), "an unclaimed gate covers")
	var host2 := FakeHost.new()
	gate2.hosted_by(host2)
	_check(not gate2.is_cover_showing() and host2.adopted.size() == 1, "hosted_by takes the cover down and tells the host")
	remove_child(root)
	root.free()
	_drop(gate2)


func _test_finding_and_old_shells() -> void:
	_section("finding the gate, and the root contract older shells read")
	var root := Node.new()
	add_child(root)
	var deep := Node.new()
	root.add_child(deep)
	var gate := DotLoadGate.new()
	gate.require_camera = false
	gate.service_scope = &"selftest"
	root.add_child(gate)
	_check(DotLoadGate.of(deep) == gate, "of() finds it from any node under the game")
	_check(DotRegistry.get_service(DotRegistry.scoped_name(DotLoadGate.SERVICE, &"selftest")) == gate, "registered under its scope")
	_check(DotLoadGate.of(self) == null, "and not from outside the game")
	_check(root.has_signal(&"ready_to_show"), "the root carries ready_to_show for an older shell")
	var heard := [0]
	root.connect(&"ready_to_show", func() -> void: heard[0] += 1)
	await _frames(6)
	_check(gate.is_open() and heard[0] == 1, "emitted on the root when it opens")
	# A root that declares its own signal keeps it, and the gate does not emit it.
	var own := preload("res://examples/load_gate_selftest_root.gd").new()
	add_child(own)
	var gate2 := DotLoadGate.new()
	gate2.register_service = false
	gate2.require_camera = false
	own.add_child(gate2)
	await _frames(6)
	_check(gate2.is_open() and own.emitted == 0, "a root with its own ready_to_show is left to emit it")
	root.remove_child(gate)
	_check(not root.has_meta(DotLoadGate.META), "leaving the tree takes the meta away")
	_check(DotRegistry.get_service(DotRegistry.scoped_name(DotLoadGate.SERVICE, &"selftest")) == null, "and the registration")
	gate.free()
	remove_child(root)
	root.free()
	remove_child(own)
	own.free()


func _section(title: String) -> void:
	_section_count += 1
	_line("== %s" % title)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		_line("  ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL %s%s" % [what, (" -- " + detail) if detail != "" else ""])


func _line(s: String) -> void:
	print(s)
