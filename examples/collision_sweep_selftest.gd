extends Node

## Exercises [DotCollisionSweep] against a real physics space: drawn floor and walls with and without collision,
## the causes it names, collision nothing is drawn at, and the [member DotCollisionSweep.play] filter.
##
## [codeblock]
## godot --headless --path . res://examples/collision_sweep_selftest.tscn
## [/codeblock]

const SECTIONS := 6
const CHECKS := 29

var _passed := 0
var _failed := 0
var _section_count := 0
var _world: Node3D


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_line("dot-core collision sweep self-test")
	_world = Node3D.new()
	add_child(_world)
	_build_world()
	# Bodies join the physics space on the next physics step; rays before it find nothing.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_test_floor()
	_test_floor_causes()
	_test_wall()
	_test_invisible()
	_test_play_filter()
	_test_report()

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


## A box body whose top face is at [param top_y], centred on [param xz], named [param label].
func _box(label: String, xz: Vector2, size: Vector3, centre_y: float) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = label
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	b.position = Vector3(xz.x, centre_y, xz.y)
	_world.add_child(b)
	return b


func _build_world() -> void:
	# Solid ground under x -10..10; nothing under x 20..30; ground 0.6 m too low under x 40..50; and 2 m too low under x 60..70.
	_box("Ground", Vector2(0, 0), Vector3(20, 1, 20), -0.5)
	_box("LowGround", Vector2(45, 0), Vector3(10, 1, 10), -1.1)
	_box("DeepGround", Vector2(65, 0), Vector3(10, 1, 10), -2.5)
	# A wall with a body in it at x = -30, an undrawn body at x = -50.
	_box("Wall", Vector2(-30, 0), Vector3(0.4, 4, 20), 2.0)
	_box("Solid", Vector2(-50, 0), Vector3(0.4, 4, 20), 2.0)


## A drawn square on y = [param y] facing up, [param half] metres each way from [param c].
static func _floor_faces(c: Vector3, half: float) -> PackedVector3Array:
	var a := c + Vector3(-half, 0, -half)
	var b := c + Vector3(half, 0, -half)
	var d := c + Vector3(half, 0, half)
	var e := c + Vector3(-half, 0, half)
	return PackedVector3Array([a, b, d, a, d, e])


## A drawn wall in the plane x = [param c].x facing +x (front faces are clockwise, so the triangles run up the far side).
static func _wall_faces(c: Vector3, half: float, height: float) -> PackedVector3Array:
	var a := c + Vector3(0, 0, -half)
	var b := c + Vector3(0, 0, half)
	var t := Vector3(0, height, 0)
	return PackedVector3Array([a, b, b + t, a, b + t, a + t])


func _sweep() -> DotCollisionSweep:
	return DotCollisionSweep.new(_world.get_world_3d().direct_space_state, 0xFFFFFFFF)


func _test_floor() -> void:
	_section("Floor: drawn ground with collision passes, without it is reported")
	var s := _sweep()
	s.add_faces(&"world", _floor_faces(Vector3(0, 0, 0), 8.0))
	s.sweep_drawn()
	_check(s.floor_samples > 0, "a covered floor was sampled (a clean report over no samples is not clean)")
	_check(s.count("floor_missing") == 0, "drawn floor on a collision top reports nothing")
	var m := _sweep()
	m.add_faces(&"world", _floor_faces(Vector3(25, 0, 0), 8.0))
	m.sweep_drawn()
	_check(m.count("floor_missing") > 0, "drawn floor over no collision is floor_missing")
	_check(m.count("floor_missing", "world") == m.count("floor_missing"), "the finding carries the face's tag")
	var e := _sweep()
	e.sweep_drawn()
	_check(e.floor_samples == 0 and e.count("floor_missing") == 0, "nothing drawn, nothing sampled")


func _test_floor_causes() -> void:
	_section("Floor causes: how far below the drawing the collision is")
	var near := _sweep()
	near.add_faces(&"displacement", _floor_faces(Vector3(45, 0, 0), 4.0))
	near.sweep_drawn()
	_check(near.count("floor_missing") > 0, "collision 0.6 m under the drawing is outside the 0.35 m tolerance")
	_check(str((near.results["floor_missing"]["by"] as Dictionary).keys()[0]).ends_with("lower<1m"), "named lower<1m")
	var deep := _sweep()
	deep.add_faces(&"displacement", _floor_faces(Vector3(65, 0, 0), 4.0))
	deep.sweep_drawn()
	_check(str((deep.results["floor_missing"]["by"] as Dictionary).keys()[0]).ends_with("lower<3m"), "2 m under is lower<3m")
	var loose := _sweep()
	loose.tolerance = 1.0
	loose.add_faces(&"displacement", _floor_faces(Vector3(45, 0, 0), 4.0))
	loose.sweep_drawn()
	_check(loose.count("floor_missing") == 0, "a wider tolerance accepts the 0.6 m step")
	var ceiling := _sweep()
	ceiling.add_faces(&"world", _floor_faces(Vector3(25, 0, 0), 4.0))
	ceiling.add_faces(&"ceiling", _floor_faces(Vector3(25, 1.0, 0), 4.0))
	ceiling.sweep_drawn([&"world"])
	_check(ceiling.floor_samples == 0, "a floor under a drawn ceiling lower than the headroom is not somewhere anyone stands")


func _test_wall() -> void:
	_section("Wall: a drawn wall needs collision at it")
	var ok := _sweep()
	ok.add_faces(&"world", _wall_faces(Vector3(-30 + 0.2, 0, 0), 8.0, 3.0))
	ok.sweep_drawn()
	_check(ok.wall_samples > 0, "the wall was sampled")
	_check(ok.count("wall_missing") == 0 and ok.count("wall_buried") == 0, "a wall drawn on the body's face reports nothing")
	var gap := _sweep()
	gap.add_faces(&"world", _wall_faces(Vector3(-10, 0, 0), 8.0, 3.0))
	gap.sweep_drawn()
	_check(gap.count("wall_missing") > 0, "a wall with no collision is wall_missing")
	var none := (gap.results["wall_missing"]["by"] as Dictionary).keys()[0] as String
	_check(none.ends_with("none"), "with nothing behind it the cause is none")
	var behind := _sweep()
	behind.add_faces(&"world", _wall_faces(Vector3(-30 + 1.5, 0, 0), 8.0, 3.0))
	behind.sweep_drawn()
	_check(behind.count("wall_missing") + behind.count("wall_buried") > 0, "a wall drawn 1.3 m off its body is found one way or the other")


func _test_invisible() -> void:
	_section("Invisible: collision nothing is drawn at")
	var stands := PackedVector3Array([Vector3(-47, 0, 0), Vector3(-47, 0, 5)])
	var bare := _sweep()
	bare.add_faces(&"world", _floor_faces(Vector3(-47, 0, 0), 2.0))
	bare.sweep_collision(stands)
	_check(bare.probe_rays == stands.size() * 9, "nine rays from each standing point")
	_check(bare.count("invisible_wall") > 0, "a body with no drawing at it is an invisible wall")
	_check(bare.count("invisible_wall", "Solid") == bare.count("invisible_wall"), "named by the body")
	var drawn := _sweep()
	drawn.add_faces(&"world", _wall_faces(Vector3(-50 - 0.2, 0, 0), 12.0, 4.0))
	drawn.add_faces(&"world", _wall_faces(Vector3(-50 + 0.2, 0, 0), 12.0, 4.0))
	drawn.sweep_collision(stands)
	_check(drawn.count("invisible_wall", "Solid") == 0, "the same body with its wall drawn on it is not")
	var labelled := _sweep()
	labelled.add_faces(&"world", _floor_faces(Vector3(-47, 0, 0), 2.0))
	labelled.sweep_collision(stands, func(_c: Object) -> String: return "Authored")
	_check(labelled.count("invisible_wall", "Authored") > 0, "label_of renames what was hit")
	var nobody := _sweep()
	nobody.sweep_collision(PackedVector3Array())
	_check(nobody.probe_rays == 0, "no standing points, no rays")


func _test_play_filter() -> void:
	_section("Play filter: only the floor plan counts")
	var s := _sweep()
	s.add_faces(&"world", _floor_faces(Vector3(25, 0, 0), 8.0))
	s.play = func(_p: Vector3) -> bool: return false
	s.sweep_drawn()
	_check(s.floor_samples == 0 and s.count("floor_missing") == 0, "a play filter that refuses everything samples nothing")
	var half := _sweep()
	half.add_faces(&"world", _floor_faces(Vector3(25, 0, 0), 8.0))
	half.play = func(p: Vector3) -> bool: return p.x < 25.0
	half.sweep_drawn()
	var all := _sweep()
	all.add_faces(&"world", _floor_faces(Vector3(25, 0, 0), 8.0))
	all.sweep_drawn()
	_check(half.count("floor_missing") > 0 and half.count("floor_missing") < all.count("floor_missing"), "half the floor plan finds fewer places than all of it")
	var tagged := _sweep()
	tagged.add_faces(&"glass", _floor_faces(Vector3(25, 0, 0), 8.0))
	tagged.sweep_drawn([&"world"])
	_check(tagged.count("floor_missing") == 0, "sweep_drawn with tags skips the others")


func _test_report() -> void:
	_section("Report: counts per kind and examples")
	var s := _sweep()
	s.add_faces(&"world", _floor_faces(Vector3(25, 0, 0), 8.0))
	s.sweep_drawn()
	var lines := s.describe_lines()
	_check(lines[0].begins_with("%d floor samples" % s.floor_samples), "the first line counts what was sampled")
	_check(lines.size() > 1 and lines[1].begins_with("floor_missing: %d places" % s.count("floor_missing")), "then each kind with its places")
	_check(lines.size() <= 2 + s.examples_per_kind, "examples are capped")
	_check(s.count("nonexistent") == 0, "an unknown kind counts zero")
	var cells := s.count("floor_missing")
	_check(cells <= int(ceil(16.0 / DotCollisionSweep.CELL)) * int(ceil(16.0 / DotCollisionSweep.CELL)) + 8, "findings are cells, not triangles")


func _check(cond: bool, what: String) -> void:
	if cond:
		_passed += 1
		_line("  PASS  " + what)
	else:
		_failed += 1
		_line("  FAIL  " + what)


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line(title)


func _line(s: String) -> void:
	print(s)
