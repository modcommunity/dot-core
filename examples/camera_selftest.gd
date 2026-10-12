extends Node3D

## Exercises [DotCameraProbe], [DotCameraBoom] and [DotCameraFade] in a real physics space.
##
## [b]Every "never inside" check is armed[/b]: the same path is first flown with no probe,
## and the suite requires that flight to put the camera inside geometry on many frames.
## A check that a camera stays out of walls on a path that never goes near a wall passes
## for the one reason it could not fail, which is how dot-player-controller's tps_selftest
## once passed with every third-person camera inside its own player.
##
## [codeblock]
## godot --headless --path . res://examples/camera_selftest.tscn
## [/codeblock]

const SECTIONS := 8
const CHECKS := 32

const WORLD := 1
const PEOPLE := 2

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_build_level()

	# Bodies are in the broadphase after a physics step, not on the frame they were added.
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _run()


func _run() -> void:
	_line("dot-core camera self-test")
	_line("")

	_test_wall_behind()
	_test_gap_a_ray_slips_through()
	await _test_scripted_path()
	await _test_boom_excludes_its_body()
	await _test_fade()
	_test_fade_without_colliders()
	_test_clip_view()
	_test_check_helper()

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


# --- the level ---------------------------------------------------------------------------

func _build_level() -> void:
	# A wall 1.5 m behind the origin, across the whole width.
	_box(Vector3(0.0, 1.5, 1.5 + 0.25), Vector3(20.0, 3.0, 0.5))

	# An arch at x = 20: two pillars and a beam with a 6 cm slit between pillar and beam,
	# which a ray down the middle of the slit passes through.
	_box(Vector3(20.0, 1.0, 3.0), Vector3(1.0, 2.0, 1.0))
	_box(Vector3(20.0, 2.53, 3.0), Vector3(1.0, 1.0, 1.0))

	# A colonnade along a corridor at z = 2.2, x from 30 to 60, every 4 m.
	for i in 8:
		_box(Vector3(30.0 + 4.0 * i, 1.5, 2.2), Vector3(0.6, 3.0, 0.6))

	# A floor under the colonnade, for pivots_near_walls to stand eyes on.
	_box(Vector3(46.0, -0.25, 0.0), Vector3(40.0, 0.5, 12.0))

	# A ceiling low over x = 70..74.
	_box(Vector3(72.0, 2.4, 0.0), Vector3(4.0, 0.3, 8.0))


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	add_child(body)
	return body


func _person(at: Vector3) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.collision_layer = PEOPLE
	body.collision_mask = WORLD
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	shape.shape = capsule
	shape.position.y = 0.9
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	mesh.mesh = CapsuleMesh.new()
	mesh.position.y = 0.9
	body.add_child(mesh)
	body.position = at
	add_child(body)
	return body


func _space() -> PhysicsDirectSpaceState3D:
	return get_world_3d().direct_space_state


func _inside(point: Vector3, radius: float) -> bool:
	return DotCameraProbe.is_inside(_space(), point, radius, WORLD)


# --- sections ----------------------------------------------------------------------------

func _test_wall_behind() -> void:
	_section("A wall between the pivot and the wanted camera pulls it in")

	var probe := DotCameraProbe.new(get_world_3d(), WORLD)
	var pivot := Vector3(0.0, 1.5, 0.0)
	var wanted := Vector3(0.0, 1.5, 3.0)
	var got := probe.resolve(pivot, wanted, 1.0 / 60.0)

	_check(got.z < 1.5 - probe.radius + 0.001, "stops short of the wall (z %.2f)" % got.z)
	_check(got.z > 1.0, "but not further in than it must (z %.2f)" % got.z)
	_check(not _inside(got, probe.radius * 0.9), "the camera sphere is clear of the wall")
	var ray := PhysicsRayQueryParameters3D.create(pivot, wanted, WORLD)
	_check(not _space().intersect_ray(ray).is_empty(), "armed: the line from the pivot crosses the wall")


func _test_gap_a_ray_slips_through() -> void:
	_section("A slit a ray passes through does not let the camera through")

	var probe := DotCameraProbe.new(get_world_3d(), WORLD)
	var pivot := Vector3(20.0, 2.015, 1.0)
	var wanted := Vector3(20.0, 2.015, 3.0)

	# Armed: a ray alone, which is what a spring arm without a shape casts, sees nothing.
	var ray := PhysicsRayQueryParameters3D.create(pivot, wanted, WORLD)
	_check(_space().intersect_ray(ray).is_empty(), "armed: a ray down the slit hits nothing")
	_check(_inside(wanted, probe.radius), "armed: and its end is inside the arch")

	var got := probe.resolve(pivot, wanted, 1.0 / 60.0)
	_check(not _inside(got, probe.radius * 0.9), "the swept camera is clear of the arch (z %.2f)" % got.z)


func _test_scripted_path() -> void:
	_section("Along a colonnade and under a ceiling: never inside, never a jump")

	var blind: Dictionary = await _fly(0.0)
	var flown: Dictionary = await _fly(-1.0)

	_line("    no look-ahead: %d snaps, largest cut %.2f m" % [blind["jumps"], blind["worst_snap"]])
	_check(int(flown["unprotected_inside"]) >= 10, "armed: with no probe the camera is inside geometry on %d frames" % flown["unprotected_inside"])
	_check(int(flown["pulled"]) >= 20, "the boom pulled in on %d frames" % flown["pulled"])
	_check(int(flown["inside"]) == 0, "with the boom it is inside on none (%d)" % flown["inside"])
	_check(int(blind["jumps"]) > 0, "armed: with no look-ahead the hard limit snaps the camera in on %d frames" % blind["jumps"])
	_check(int(flown["jumps"]) == 0, "with it, never: no cut of 0.3 m, no frame 0.4 m further than the view moved (%d)" % flown["jumps"])


## Flies the boom down the colonnade. [param look_ahead] below zero keeps the probe's own.
func _fly(look_ahead: float) -> Dictionary:
	var boom := DotCameraBoom.new()
	boom.spring_length = 3.5
	boom.side_offset = 0.6
	boom.collision_mask = WORLD
	var mount := Node3D.new()
	mount.position = Vector3(28.0, 1.6, 0.0)
	add_child(mount)
	mount.add_child(boom)
	var camera := Node3D.new()
	boom.add_child(camera)
	if look_ahead >= 0.0:
		boom.probe.look_ahead = look_ahead

	boom.rotation.x = -0.35
	boom.force_update()

	var frames := 0
	var inside := 0
	var unprotected_inside := 0
	var jumps := 0
	var pulled := 0
	var worst := 0.0
	var worst_snap := 0.0
	var last := camera.global_position
	var last_wanted := boom.global_transform * boom.wanted_local()
	var delta := 1.0 / 60.0

	# 50 m in 8 s at a running pace, swinging the boom between straight behind and well
	# towards the pillars and back twice, the camera pitched up through a low ceiling.
	for i in 480:
		var t := float(i) / 480.0
		mount.position = Vector3(28.0 + 50.0 * t, 1.6, 0.0)
		boom.rotation.y = sin(t * TAU * 2.0) * 0.9
		boom.place(delta)

		var at := camera.global_position
		var wanted := boom.global_transform * boom.wanted_local()
		frames += 1

		if _inside(at, boom.margin * 0.9):
			inside += 1

		if _inside(wanted, boom.margin * 0.9):
			unprotected_inside += 1

		if boom.get_hit_length() < boom.wanted_local().length() - 0.05:
			pulled += 1

		# A snap is the camera moving much further than the place it wants to be moved:
		# the collision answer jumping, not the view swinging.
		var extra := at.distance_to(last) - wanted.distance_to(last_wanted)
		worst = maxf(worst, extra)

		# Riding a limit that falls continuously, the eased camera lags it by centimetres
		# and the clamp takes them; that is continuous. A snap is a cut of a third of a metre.
		worst_snap = maxf(worst_snap, boom.probe.last_snap())

		if boom.probe.last_snap() > 0.3 or extra > 0.4:
			jumps += 1

		if OS.get_environment("CAMERA_DEBUG") != "":
			print("%3d x %.2f yaw %+.2f len %.2f extra %.2f %s" % [i, mount.position.x, boom.rotation.y, boom.get_hit_length(), extra, boom.probe.describe()])

		last = at
		last_wanted = wanted

		if i % 30 == 0:
			await get_tree().process_frame

	_line("    %d frames, %d pulled in, %d unprotected frames inside, %d inside, %d snaps, largest extra step %.2f m, largest cut %.2f m" % [
		frames, pulled, unprotected_inside, inside, jumps, worst, worst_snap,
	])
	mount.queue_free()
	await get_tree().process_frame

	return {
		"unprotected_inside": unprotected_inside, "pulled": pulled, "inside": inside,
		"jumps": jumps, "worst_snap": worst_snap,
	}


func _test_boom_excludes_its_body() -> void:
	_section("A boom hung off a body is stopped by other bodies, never by its own")

	var body := _person(Vector3(-20.0, 0.0, -10.0))
	var boom := DotCameraBoom.new()
	boom.spring_length = 3.0
	boom.collision_mask = WORLD | PEOPLE
	boom.position = Vector3(0.0, 1.4, 0.0)
	body.add_child(boom)
	var camera := Node3D.new()
	boom.add_child(camera)

	await get_tree().physics_frame
	await get_tree().physics_frame

	# The pivot is inside its own capsule, which both sweeps ignore (cast_motion skips
	# what it starts in; a ray does not hit a shape from inside). A spring arm's ray did
	# the opposite and collapsed into its own player until each game excluded it.
	boom.force_update()
	_check(is_equal_approx(boom.get_hit_length(), 3.0), "its own body never stops it (%.2f m)" % boom.get_hit_length())

	boom.exclude_ancestors()
	var other := _person(Vector3(-20.0, 0.0, -8.5))
	await get_tree().physics_frame
	await get_tree().physics_frame
	boom.force_update()
	_check(boom.get_hit_length() < 1.2, "somebody standing behind does, on a mask that has them (%.2f m)" % boom.get_hit_length())

	body.queue_free()
	other.queue_free()


func _test_fade() -> void:
	_section("A body between the camera and its focus fades; one at the camera is hidden")

	var camera := Camera3D.new()
	camera.position = Vector3(-40.0, 1.6, 4.0)
	add_child(camera)
	var focus := Node3D.new()
	focus.position = Vector3(-40.0, 1.6, 0.0)
	add_child(focus)

	var fade := DotCameraFade.new()
	fade.collision_mask = PEOPLE
	fade.focus = focus
	camera.add_child(fade)

	var between := _person(Vector3(-40.0, 0.0, 2.0))
	var own_camera := Camera3D.new()
	between.add_child(own_camera)
	var gun := MeshInstance3D.new()
	gun.mesh = BoxMesh.new()
	own_camera.add_child(gun)
	var aside := _person(Vector3(-35.0, 0.0, 2.0))

	await get_tree().physics_frame
	await get_tree().physics_frame

	for i in 30:
		fade.update(camera.global_position, focus.global_position, 1.0 / 60.0)

	var body_mesh := between.get_child(1) as GeometryInstance3D
	_check(body_mesh.transparency > 0.6, "the body on the line is faded (%.2f)" % body_mesh.transparency)
	_check(gun.transparency == 0.0, "but not the view model under its camera")
	_check((aside.get_child(1) as GeometryInstance3D).transparency == 0.0, "a body off the line is untouched")

	between.position = Vector3(-40.0, -0.2, 4.0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	for i in 30:
		fade.update(camera.global_position, focus.global_position, 1.0 / 60.0)

	_check(body_mesh.transparency > 0.95, "a body at the camera is hidden (%.2f)" % body_mesh.transparency)

	between.position = Vector3(-46.0, 0.0, 4.0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	for i in 60:
		fade.update(camera.global_position, focus.global_position, 1.0 / 60.0)

	_check(body_mesh.transparency == 0.0, "and back when it has gone (%.2f)" % body_mesh.transparency)
	_check(fade.faded_count() == 0, "with nothing left faded")

	camera.queue_free()
	focus.queue_free()
	between.queue_free()
	aside.queue_free()


func _test_fade_without_colliders() -> void:
	_section("Characters with no collider fade through bodies_fn")

	var camera := Camera3D.new()
	camera.position = Vector3(-60.0, 1.6, 4.0)
	add_child(camera)
	var fade := DotCameraFade.new()
	var figures: Array = []
	fade.bodies_fn = func() -> Array: return figures
	camera.add_child(fade)

	var figure := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	figure.add_child(mesh)
	figure.position = Vector3(-60.0, 0.0, 2.0)
	add_child(figure)
	figures.append(figure)

	for i in 30:
		fade.update(camera.global_position, Vector3(-60.0, 1.6, 0.0), 1.0 / 60.0)
	_check(mesh.transparency > 0.6, "one on the line to the focus is faded (%.2f)" % mesh.transparency)

	figure.position = Vector3(-60.0, 0.2, 4.2)
	for i in 30:
		fade.update(camera.global_position, camera.global_position, 1.0 / 60.0)
	_check(mesh.transparency > 0.95, "one walking into a first-person camera is hidden (%.2f)" % mesh.transparency)

	figure.position = Vector3(-60.0, 0.0, 6.0)
	for i in 60:
		fade.update(camera.global_position, camera.global_position, 1.0 / 60.0)
	_check(mesh.transparency == 0.0, "a step away and it is back (%.2f)" % mesh.transparency)

	figure.position = Vector3(-60.0, 0.0, 3.0)
	for i in 60:
		fade.update(camera.global_position, camera.global_position, 1.0 / 60.0)
	_check(mesh.transparency == 0.0, "and a metre off, in first person, it is left alone")

	camera.queue_free()
	figure.queue_free()


func _test_clip_view() -> void:
	_section("clip_view keeps the basis and pulls the origin in")

	var probe := DotCameraProbe.new(get_world_3d(), WORLD)
	var basis := Basis(Vector3.UP, 0.7)
	var got := probe.clip_view(Vector3(0.0, 1.5, 0.0), Transform3D(basis, Vector3(0.0, 1.5, 3.0)))
	_check(got.basis.is_equal_approx(basis), "the basis is the one asked for")
	_check(got.origin.z < 1.5, "the origin is in front of the wall (z %.2f)" % got.origin.z)
	_check(not _inside(got.origin, probe.radius * 0.9), "and clear of it")

	var none := DotCameraProbe.new(null, WORLD)
	_check(none.clip_view(Vector3.ZERO, Transform3D(basis, Vector3(0, 0, 3))).origin.z == 3.0, "a probe with no world returns what it was asked")


func _test_check_helper() -> void:
	_section("DotCameraCheck, the games' tool, is armed")

	var near_pillars := DotCameraCheck.fly(get_world_3d(), DotCameraCheck.orbit_path(Vector3(34.0, 1.6, 1.0)), Vector3(0.45, 0.35, 2.6), WORLD)
	_line("    " + DotCameraCheck.summary(near_pillars))
	_check(DotCameraCheck.passed(near_pillars), "an orbit beside a pillar passes: armed and never inside")

	var open := DotCameraCheck.fly(get_world_3d(), DotCameraCheck.orbit_path(Vector3(0.0, 1.6, -30.0)), Vector3(0.45, 0.35, 2.6), WORLD)
	_check(not DotCameraCheck.passed(open), "an orbit in the open fails: it never went near a wall, so it proved nothing")

	var found := DotCameraCheck.pivots_near_walls(get_world_3d(), AABB(Vector3(26.0, -1.0, -3.0), Vector3(40.0, 5.0, 4.0)), WORLD, 1.6, 2.0, 3.0, 10)
	_check(found.size() > 0 and found.size() <= 10 and found.all(func(p: Vector3) -> bool: return not _inside(p, 0.3)), "pivots_near_walls finds clear eyes beside the colonnade (%d)" % found.size())

	var total := DotCameraCheck.add(DotCameraCheck.add({}, near_pillars), open)
	_check(int(total["frames"]) == int(near_pillars["frames"]) + int(open["frames"]), "flights add up")


# --- reporting ---------------------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("  ok    %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
