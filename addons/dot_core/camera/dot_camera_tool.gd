class_name DotCameraTool
extends SceneTree

## The camera render-and-check every game's `tools/render_cameras.gd` is: a game names its
## level, the pivots worth flying round (spawns, a start line, a route) and its cameras'
## offsets, and this flies them, fails on any frame inside the level, and draws the worst
## case before and after so a person can look at it.
##
## [codeblock]
## extends DotCameraTool
## func _build_level() -> Node3D: return MyMap.build("dm_box")
## func _pivots() -> Array[Vector3]: return my_spawn_eyes
## [/codeblock]
##
## [codeblock]
## xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_cameras.gd
## [/codeblock]
##
## Writes `screenshots/cameras/<name>_<case>_{before,after}.png`:
##
## - [b]third_person / chase[/b]: the frame of the flight where the unprotected camera was
##   deepest in or behind the level, drawn from there (before) and from where the probe put
##   it (after);
## - [b]between[/b]: somebody standing between that camera and the player, drawn plain and
##   with dot-core's [DotCameraFade];
## - [b]walk_in[/b]: somebody walking into a first-person camera, plain and faded.
##
## Exits 1 when a flight fails [method DotCameraCheck.passed]: the unprotected camera never
## went near a wall (the check was not armed), or the probed one ended inside on a frame.
## Needs a renderer, so not `--headless`; with `--no-render` it only flies, which runs
## headless and is what a suite can call.

var _out_dir := "screenshots/cameras"
var _name := "game"
var _render := true
var _camera: Camera3D = null
var _failed := false


## The level, as a node to add to the root: drawn and colliding.
func _build_level() -> Node3D:
	return Node3D.new()


## Light for the frames. A game whose level brings its own returns an empty node.
func _build_lighting() -> Node3D:
	var root := Node3D.new()
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(35.0), 0.0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.68, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.66)
	env.ambient_light_energy = 0.8
	environment.environment = env
	root.add_child(environment)
	return root


## Eye positions to fly the cameras round: spawns, the places a play test went wrong.
func _pivots() -> Array[Vector3]:
	return []


## The cameras, by case name: an offset from the eye in the view's axes (right, up, back).
func _offsets() -> Dictionary:
	return {"third_person": Vector3(0.45, 0.35, 2.6), "chase": Vector3(0.0, 0.9, 3.5)}


## Layers the cameras stop against.
func _level_mask() -> int:
	return 1


## What stands for a person in the frames. A game returns its own figure, feet at the origin.
func _figure(tint: Color) -> Node3D:
	var root := Node3D.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.32
	capsule.height = 1.5
	body.mesh = capsule
	body.position.y = 0.75
	body.material_override = material
	root.add_child(body)
	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.4
	head.mesh = sphere
	head.position.y = 1.62
	head.material_override = material
	root.add_child(head)
	return root


## Metres from feet to eye, for placing figures under pivots.
func _eye_height() -> float:
	return 1.6


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_render = not args.has("--no-render") and DisplayServer.get_name() != "headless"
	var at := args.find("--out")
	if at >= 0 and at + 1 < args.size():
		_out_dir = args[at + 1]
	at = args.find("--name")
	if at >= 0 and at + 1 < args.size():
		_name = args[at + 1]
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	root.add_child(_build_level())
	if _render:
		root.add_child(_build_lighting())
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.near = 0.05
	root.add_child(_camera)
	_camera.make_current()

	for i in 4:
		await physics_frame

	var world := root.get_world_3d()
	var mask := _level_mask()
	var pivots := _pivots()

	if pivots.is_empty():
		print("camera tool: no pivots to fly round")
		quit(1)
		return

	var offsets := _offsets()

	for case_name in offsets.keys():
		var offset: Vector3 = offsets[case_name]
		var total: Dictionary = {}
		var worst: Dictionary = {}
		var worst_depth := 0.0

		for pivot in pivots:
			var got := DotCameraCheck.fly(world, DotCameraCheck.orbit_path(pivot), offset, mask)
			for pose in got["poses"]:
				var depth := (pose["wanted"] as Vector3).distance_to(pose["got"] as Vector3)
				if depth > worst_depth:
					worst_depth = depth
					worst = pose
			total = DotCameraCheck.add(total, got)

		var ok := DotCameraCheck.passed(total, 1)
		_failed = _failed or not ok
		print("%s %-13s %s  %s" % [_name, case_name, "ok  " if ok else "FAIL", DotCameraCheck.summary(total)])

		if _render and not worst.is_empty():
			await _shoot_case(String(case_name), worst)

	if _render and not pivots.is_empty():
		await _shoot_walk_in(pivots[0])

	quit(1 if _failed else 0)


func _shoot_case(case_name: String, pose: Dictionary) -> void:
	var pivot: Vector3 = pose["pivot"]
	var basis: Basis = pose["basis"]
	var me := _figure(Color(0.95, 0.55, 0.15))
	me.position = pivot - Vector3.UP * _eye_height()
	me.rotation.y = basis.get_euler().y
	root.add_child(me)

	await _frame(Transform3D(basis, pose["wanted"]), "%s_%s_before" % [_name, case_name])
	await _frame(Transform3D(basis, pose["got"]), "%s_%s_after" % [_name, case_name])

	# Somebody between the camera and the player: two thirds of the way back.
	var from: Vector3 = pose["got"]
	var between := _figure(Color(0.25, 0.55, 0.9))
	var spot := pivot.lerp(from, 0.55)
	between.position = Vector3(spot.x, me.position.y, spot.z)
	root.add_child(between)
	await _frame(Transform3D(basis, from), "%s_%s_between_before" % [_name, case_name])

	var fade := DotCameraFade.new()
	fade.bodies_fn = func() -> Array: return [between]
	fade.focus = me
	fade.focus_clearance = 0.0
	_camera.add_child(fade)
	var focus := Node3D.new()
	root.add_child(focus)
	focus.global_position = pivot
	fade.focus = focus
	for i in 20:
		await process_frame
	await _frame(Transform3D(basis, from), "%s_%s_between_after" % [_name, case_name])
	fade.queue_free()
	focus.queue_free()
	between.queue_free()
	me.queue_free()
	await process_frame


func _shoot_walk_in(pivot: Vector3) -> void:
	var basis := Basis.from_euler(Vector3(-0.05, 0.3, 0.0))
	var bot := _figure(Color(0.3, 0.75, 0.35))
	var ahead := pivot - basis.z * 0.2
	bot.position = Vector3(ahead.x, pivot.y - _eye_height(), ahead.z)
	bot.rotation.y = basis.get_euler().y + PI
	root.add_child(bot)
	await _frame(Transform3D(basis, pivot), "%s_walk_in_before" % _name)

	var fade := DotCameraFade.new()
	fade.bodies_fn = func() -> Array: return [bot]
	_camera.add_child(fade)
	for i in 20:
		await process_frame
	await _frame(Transform3D(basis, pivot), "%s_walk_in_after" % _name)
	fade.queue_free()
	bot.queue_free()
	await process_frame


func _frame(where: Transform3D, file: String) -> void:
	_camera.global_transform = where
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_out_dir, file]
	var _saved := image.save_png(path)
	print("  wrote %s" % path)
