extends Node3D

## Exercises [DotCameraProbe], [DotCameraBoom] and [DotCameraFade] in a real physics space.
## Every "never inside" check is armed: the same path is first flown with no probe and must put the camera inside geometry on many frames,
## else a path that never nears a wall passes for the one reason it could not fail.

const SECTIONS := 13
const CHECKS := 77

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
	await _test_render_warmup()
	_test_view_lens()

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


# the level

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


# sections

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

	# The second frame of a flight is the first the probe can look ahead from (the first is a cut, with no
	# history): a wall the view turns onto in that one step cannot have been predicted, and is not a snap
	# the look-ahead was too slow for. Armed: the same turn one frame later is counted.
	var behind := Vector3(0.0, 0.0, 3.0)
	var pivot := Vector3(0.0, 1.6, 0.0)
	var turned: Array[Transform3D] = [Transform3D(Basis(Vector3.UP, PI), pivot), Transform3D(Basis.IDENTITY, pivot), Transform3D(Basis.IDENTITY, pivot)]
	var first_turn := DotCameraCheck.fly(get_world_3d(), turned, behind, WORLD)
	_check(int(first_turn["snaps"]) == 0 and float(first_turn["worst_snap"]) == 0.0, "the first step after a flight starts is not a snap")
	var later: Array[Transform3D] = [turned[0], turned[0], turned[1]]
	var later_turn := DotCameraCheck.fly(get_world_3d(), later, behind, WORLD)
	_check(int(later_turn["snaps"]) == 1, "a turn onto a wall after the first step still counts as a snap (%.2f m)" % float(later_turn["worst_snap"]))

	var total := DotCameraCheck.add(DotCameraCheck.add({}, near_pillars), open)
	_check(int(total["frames"]) == int(near_pillars["frames"]) + int(open["frames"]), "flights add up")


func _test_render_warmup() -> void:
	_section("DotRenderWarmup collects a scene's materials and draws them out of sight")

	var scene := Node3D.new()
	var a := StandardMaterial3D.new()
	var b := StandardMaterial3D.new()
	b.cull_mode = BaseMaterial3D.CULL_DISABLED  # a distinct pipeline: identical ones are deduped
	var box := BoxMesh.new()
	box.material = a
	for i in 3:
		var mi := MeshInstance3D.new()
		mi.mesh = box
		scene.add_child(mi)
	var over := MeshInstance3D.new()
	over.mesh = box
	over.material_override = b
	scene.add_child(over)
	var sparks := GPUParticles3D.new()
	sparks.process_material = ParticleProcessMaterial.new()
	scene.add_child(sparks)

	var items := DotRenderWarmup.collect(scene)
	# The box, its material, the override, and the particles' process material: each once,
	# however many instances share it.
	_check(items.size() == 4 and items.has(box) and items.has(a) and items.has(b), "collect finds each mesh and material once (%d)" % items.size())
	_check(DotRenderWarmup.collect(scene, items).size() == 4, "collecting into the same list adds nothing twice")

	var cam := Camera3D.new()
	cam.near = 0.1
	add_child(cam)
	var warm := DotRenderWarmup.new()
	warm.timeout_sec = 0.3
	cam.add_child(warm)
	warm.add_items(items)
	warm.add_items([a, "not a resource", null])
	_check(warm.item_count() == 4, "add_items ignores repeats and anything it cannot draw")
	warm.start()
	var placed := warm.get_children()
	var inside := placed.all(func(n: Node) -> bool:
		var at := (n as Node3D).global_position
		return cam.is_position_in_frustum(at) and cam.global_position.distance_to(at) < 0.2)
	_check(placed.size() == 4 and inside, "every item is placed just past the near plane, inside the frustum")
	# Headless never draws, so this is the timeout: a cover waiting on it must still lift.
	var got: int = await warm.finished
	_check(got == 4, "finished fires even when nothing is drawn, with the count drawn")
	await get_tree().process_frame
	_check(not is_instance_valid(warm), "and the warmup frees itself")
	var cut := DotRenderWarmup.new()
	cut.batch_size = 3
	cut.timeout_sec = 0.3
	cam.add_child(cut)
	cut.add_items(items)
	cut.start()
	_check(cut.batch_count() == 2 and cut.get_child_count() == 3, "a batch size splits the items across frames (%d up, %d rounds)" % [cut.get_child_count(), cut.batch_count()])
	await cut.finished
	await _render_warmup_paced(cam)
	cam.queue_free()
	scene.free()
	_test_render_warmup_dedupe()

	_test_render_warmup_order()
	await _test_render_warmup_many_surfaces()
	await _test_render_warmup_follow_cancel()


## follow_camera keeps the warm-up on the viewport's camera wherever it is parented; cancel() stops it with no warning.
func _test_render_warmup_follow_cancel() -> void:
	_section("DotRenderWarmup follows the viewport camera and cancels silently")
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	cam.global_position = Vector3(5, 1, 2)
	var host := Node.new()
	add_child(host)
	var warm := DotRenderWarmup.new()
	warm.follow_camera = true
	warm.timeout_sec = 5.0
	host.add_child(warm)
	warm.add_items([StandardMaterial3D.new()])
	warm.start()
	_check(warm.top_level and warm.global_position.distance_to(cam.global_position) < 0.2, "under a plain node it sits at the camera")
	cam.global_position = Vector3(-3, 0, 9)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(warm.global_position.distance_to(cam.global_position) < 0.2, "and moves with the camera")
	var seen: Array = []
	var sink := func(rec: Dictionary) -> void: seen.append(rec)
	DotLog.add_sink(sink)
	_check(warm.is_running(), "it is running")
	warm.cancel()
	await get_tree().process_frame
	DotLog.remove_sink(sink)
	var warned := seen.filter(func(r: Dictionary) -> bool: return int(r["level"]) >= DotLog.Level.WARN)
	_check(not is_instance_valid(warm) and warned.is_empty(), "cancel() frees it with no warning")
	host.queue_free()
	var loose := DotRenderWarmup.new()
	loose.cancel()
	await get_tree().process_frame
	_check(not is_instance_valid(loose), "cancel() out of the tree frees it a frame later")
	cam.queue_free()


## The dear compiles are drawn first, equal costs keep their queue order, and off keeps the queue as given.
func _test_render_warmup_order() -> void:
	_section("DotRenderWarmup draws the dear compiles first")
	var plain := StandardMaterial3D.new()
	var lit := StandardMaterial3D.new()
	lit.normal_enabled = true
	lit.normal_texture = PlaceholderTexture2D.new()
	var shader_small := ShaderMaterial.new()
	shader_small.shader = Shader.new()
	shader_small.shader.code = "shader_type spatial;"
	var shader_big := ShaderMaterial.new()
	shader_big.shader = Shader.new()
	shader_big.shader.code = "shader_type spatial;\n" + "// pad\n".repeat(400)
	var proc := ParticleProcessMaterial.new()
	var quad := QuadMesh.new()
	var queue: Array = [quad, plain, shader_small, lit, proc, shader_big]
	_check(DotRenderWarmup.item_cost(lit) > DotRenderWarmup.item_cost(plain), "a material with a normal map costs more than a plain one")
	_check(DotRenderWarmup.item_cost(shader_big) > DotRenderWarmup.item_cost(shader_small), "a longer shader costs more")
	_check(DotRenderWarmup.item_cost(shader_small) > DotRenderWarmup.item_cost(lit), "a shader costs more than a material")
	var warm := DotRenderWarmup.new()
	warm.dedupe = false
	warm.dear_first = true
	warm.first_batch = 100
	warm.timeout_sec = 0.1
	add_child(warm)
	warm.add_items(queue)
	warm.start()
	var order: Array = []
	for child in warm.get_children():
		order.append(child)
	var cost_order := true
	var last := INF
	for child in order:
		var item: Variant = (child as MeshInstance3D).material_override if (child is MeshInstance3D and (child as MeshInstance3D).material_override != null) else (child as MeshInstance3D).mesh if child is MeshInstance3D else (child as GPUParticles3D).process_material
		var c := DotRenderWarmup.item_cost(item)
		if c > last:
			cost_order = false
		last = c
	_check(order.size() == 6 and cost_order, "placed in falling cost (%d items)" % order.size())
	await warm.finished
	var off := DotRenderWarmup.new()
	off.dedupe = false
	off.timeout_sec = 0.1
	add_child(off)
	off.add_items(queue)
	off.start()
	_check(off.get_child(0) is MeshInstance3D, "off keeps the queue order (the particles, fifth, are not first)")
	await off.finished


## Items that compile one pipeline are queued once; distinct pipelines all stay.
func _test_render_warmup_dedupe() -> void:
	_section("DotRenderWarmup queues one item per pipeline")
	var plain: Array = []
	for i in 6:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(i * 0.1, 0.2, 0.3)  # a uniform: same shader
		plain.append(m)
	var trans := StandardMaterial3D.new()
	trans.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var textured := StandardMaterial3D.new()
	textured.albedo_texture = PlaceholderTexture2D.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(1.0); }"
	var sm_a := ShaderMaterial.new()
	sm_a.shader = shader
	var sm_b := ShaderMaterial.new()
	sm_b.shader = shader
	var other := Shader.new()
	other.code = "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(0.5); }"
	var sm_c := ShaderMaterial.new()
	sm_c.shader = other
	var particles := [ParticleProcessMaterial.new(), ParticleProcessMaterial.new()]
	var box_a := BoxMesh.new()
	box_a.material = plain[0]
	var box_b := BoxMesh.new()
	box_b.material = plain[1]
	var box_t := BoxMesh.new()
	box_t.material = trans
	var all: Array = plain + [trans, textured, sm_a, sm_b, sm_c, box_a, box_b, box_t] + particles

	var warm := DotRenderWarmup.new()
	warm.add_items(all)
	# plain x6 -> 1, trans, textured, sm_a/sm_b -> 1, sm_c, box_a/box_b -> 1, box_t; the particles are kept (2)
	_check(warm.item_count() == 1 + 1 + 1 + 1 + 1 + 1 + 1 + 2, "%d items queue as %d pipelines" % [all.size(), warm.item_count()])
	_check(warm.skipped_count() == all.size() - warm.item_count() and int(warm.describe()["deduped"]) == warm.skipped_count(), "the skipped ones are counted (%d)" % warm.skipped_count())
	_check(warm._items.has(plain[0]) and not warm._items.has(plain[1]), "the first of a pipeline is the one kept")
	_check(warm._items.has(trans) and warm._items.has(textured) and warm._items.has(sm_c) and warm._items.has(box_t), "distinct pipelines are kept")
	warm.free()
	var off := DotRenderWarmup.new()
	off.dedupe = false
	off.add_items(all)
	_check(off.item_count() == all.size() and off.skipped_count() == 0, "dedupe off keeps every item (%d)" % off.item_count())
	off.free()
	var again := DotRenderWarmup.new()
	again.add_items(plain)
	again.add_items(plain)
	_check(again.item_count() == 1, "a second add of the same items adds nothing")
	again.free()
	_test_render_warmup_dedupe_meshes()


## Meshes that differ in vertex format or blend shapes compile different pipelines and stay; the same layout merges.
func _test_render_warmup_dedupe_meshes() -> void:
	var mat := StandardMaterial3D.new()
	var meshes: Array = []
	for variant in [0, 2, 3]:
		var am := ArrayMesh.new()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		if variant == 2:
			arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.RED, Color.RED, Color.RED])
		var shapes: Array = []
		if variant == 3:
			am.add_blend_shape("s")
			shapes.append(arrays.duplicate())
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, shapes)
		am.surface_set_material(0, mat)
		meshes.append(am)
	var copy := meshes[0].duplicate() as ArrayMesh
	var warm := DotRenderWarmup.new()
	warm.add_items(meshes + [copy])
	_check(warm.item_count() == 3, "plain, vertex colour and blend shape meshes stay apart; a copy merges (%d)" % warm.item_count())
	warm.free()
	var prim_a := BoxMesh.new()
	var prim_b := BoxMesh.new()
	prim_b.add_uv2 = true
	var warm_p := DotRenderWarmup.new()
	warm_p.add_items([prim_a, prim_b])
	_check(warm_p.item_count() == 2, "primitive meshes filling different arrays stay apart")
	warm_p.free()


## A budget_msec warm-up starts small and sizes each next round from the measured cost per item.
func _render_warmup_paced(cam: Camera3D) -> void:
	var mats: Array = []
	for i in 40:
		mats.append(StandardMaterial3D.new())
	var paced := DotRenderWarmup.new()
	paced.dedupe = false  # forty identical materials, to be sized, not merged
	paced.budget_msec = 40.0
	paced.timeout_sec = 0.3
	cam.add_child(paced)
	paced.add_items(mats)
	paced.start()
	_check(paced.get_child_count() == DotRenderWarmup.FIRST_BATCH, "a budgeted warm-up starts with a small round (%d up)" % paced.get_child_count())
	# 16 items drew in a 26 ms frame where an empty one takes 10: 1 ms each, 30 ms of room.
	paced._round_placed = 16
	paced._base_usec = 10000
	paced._first_cost_usec = 26000
	paced._resize()
	_check(paced._cap == 30, "the next round is sized from the measured cost per item (%d)" % paced._cap)
	paced._first_cost_usec = 900000
	paced._resize()
	_check(paced._cap == DotRenderWarmup.MIN_BATCH, "a round far over budget shrinks the next to the floor (%d)" % paced._cap)
	# 16 cheap items right after that: their mean says 30000 more, but the dear item is remembered, halving per round.
	paced._first_cost_usec = 10100
	paced._resize()
	_check(paced._cap == 1, "a cheap round right after a dear one keeps the next small (%d)" % paced._cap)
	paced._resize()
	paced._resize()
	_check(paced._cap == 4, "the dear item's weight halves each round that keeps to the budget (%d)" % paced._cap)
	# dear_decay 1 holds a dear item for good: cheap rounds never grow past one item again.
	paced.dear_decay = 1.0
	paced._dear_usec = 55000.0
	for i in 8:
		paced._resize()
	_check(paced._cap == 1 and paced._dear_usec == 55000.0, "dear_decay 1 holds the dear item: rounds stay at one (%d)" % paced._cap)
	paced.dear_decay = DotRenderWarmup.DEAR_DECAY
	paced._dear_usec = 0.0
	paced._resize()
	_check(paced._cap == 32, "a cheap round grows the next at most by growth, twofold (%d)" % paced._cap)
	paced.growth = 0.0
	paced._resize()
	_check(paced._cap == paced.batch_size, "growth 0 is no limit: batch_size is the only one (%d)" % paced._cap)
	paced.growth = DotRenderWarmup.GROWTH
	# Bare frames of 60 ms against a 40 ms budget: the warm-up still gets half the budget, not one item a round.
	paced._base_usec = 60000
	paced._round_placed = 1
	paced._first_cost_usec = 61000
	paced._resize()
	_check(paced._cap == 2, "a device slower than the budget still grows its rounds (%d)" % paced._cap)
	var seen := paced.describe()
	_check(seen.has("longest_round_ms") and seen.has("left") and int(seen["left"]) == paced.left() and paced.left() > 0, "describe reports the longest round and the items left (%s)" % seen)
	await paced.finished


func _test_render_warmup_many_surfaces() -> void:
	# A converted map is hundreds of surfaces over a few materials; drawn whole it was an
	# 18000-call frame. One triangle per material and format is the same pipelines for ~3 calls.
	var big := ArrayMesh.new()
	var mats := [StandardMaterial3D.new(), StandardMaterial3D.new(), StandardMaterial3D.new()]
	for i in 250:  # the engine refuses a mesh past 256 surfaces
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		var o := Vector3(i * 5.0, 0, 0)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([o, o + Vector3.RIGHT, o + Vector3.UP, o + Vector3.ONE])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 2, 1, 3])
		big.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		big.surface_set_material(i, mats[i % 3])
	var cam2 := Camera3D.new()
	add_child(cam2)
	var warm2 := DotRenderWarmup.new()
	warm2.dedupe = false  # the proxy cache is under test, not the item key
	warm2.timeout_sec = 0.3
	cam2.add_child(warm2)
	warm2.add_items([big])
	warm2.start()
	var proxy := (warm2.get_child(0) as MeshInstance3D).mesh
	_check(proxy.get_surface_count() == 3, "a many-surface mesh is warmed as one triangle per material (%d surfaces)" % proxy.get_surface_count())
	_check(proxy.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2] != null, "and keeps the vertex format of the surface")
	# A second mesh over the same materials and format has nothing new to draw, and must not
	# leave a bare MeshInstance3D behind each time (420 orphans per world build in mg-wipeout).
	var orphans_before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	warm2.add_items([big.duplicate()])
	warm2._place_batch()
	var orphans_after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	_check(warm2.get_child_count() == 1 and orphans_after == orphans_before, "a mesh with nothing new places nothing and leaves no orphan (%d to %d)" % [orphans_before, orphans_after])
	var _g: int = await warm2.finished
	cam2.queue_free()


# reporting

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _test_view_lens() -> void:
	_section("DotViewLens draws a held model at its own lens")

	_check(absf(DotViewLens.vertical_from_horizontal_4_3(100.0) - 83.6) < 0.1, "100 degrees across 4:3 is about 83.6 vertical")
	_check(is_equal_approx(DotViewLens.lens_scale(70.0, 70.0), 1.0), "the same lens is a scale of 1")
	_check(DotViewLens.lens_scale(80.0, 0.0) == 1.0, "an unusable lens is a scale of 1")
	var cam := Camera3D.new()
	cam.fov = 90.0
	var model := Node3D.new()
	DotViewLens.apply(model, cam, 60.0, 1.0, 0.05)
	var k := DotViewLens.lens_scale(90.0, 60.0)
	_check(is_equal_approx(model.scale.x, k) and model.scale.z == 1.0, "apply scales X and Y by the lens")
	_check(is_equal_approx(model.position.z, -(k - 1.0) * DotViewLens.REFERENCE_DEPTH + 0.05), "and pulls it in, then adds the extra")
	cam.free()
	model.free()


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("  ok    %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
