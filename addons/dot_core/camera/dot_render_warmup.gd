class_name DotRenderWarmup
extends Node3D

## Draws every material a scene will need once, out of sight, so their shaders compile while
## something covers the screen instead of in the middle of play.
##
## [codeblock]
## var warm := DotRenderWarmup.new()
## camera.add_child(warm)
## warm.add_items(DotRenderWarmup.collect(level))
## warm.add_items(game_extras)          # Materials, Meshes, ParticleProcessMaterials
## warm.start()
## await warm.finished                  # it frees itself
## [/codeblock]
##
## [b]Why it is needed.[/b] A renderer compiles a material's shader the first time something
## using it is drawn, and under the Compatibility renderer (every browser) that compile and
## the program link are synchronous on the one thread the game has: a material first seen in
## a fight (a muzzle flash, an impact, the first enemy's character) stops the frame for tens
## to hundreds of milliseconds in a browser. Nothing can compile a shader ahead of time
## without drawing it, so this draws it.
##
## [b]How it hides.[/b] Each item is put on a tiny instance just past the camera's near
## plane, inside the frustum. Culling is by bounds on the CPU, not by covered pixels, so a
## millimetre-sized quad is submitted and its program built exactly as a full-screen one
## would be, and a player who sees the frame sees nothing. It still costs the compile, which
## is the point: start it under a loading screen.
##
## [b]What it cannot reach.[/b] A shader's variant depends on what draws it as well as on
## the material: lit by an omni light or not, skinned or not, with fog or shadows. Items are
## drawn as they are in the scene's light (casting shadows, under the camera's environment),
## and a [Mesh] is drawn as itself so its vertex format matches; a skinned mesh still warms
## the unskinned variant, and a light that appears later (a muzzle flash's) adds variants
## nobody drew. It removes the bulk of the first-use stalls, not every one.

const CHANNEL := "dot.render_warmup"

## Emitted once the items have been drawn for [member frames] frames and removed.
signal finished(count: int)

## Frames the items stay up. Two: the first draw compiles, and a renderer that compiles a
## shadow or depth variant a frame later gets its second chance.
@export var frames: int = 2

## Seconds after which [signal finished] fires anyway: a headless run or a hidden window
## never draws, and a cover waiting on this must not wait for ever.
@export var timeout_sec: float = 5.0

## Side of each instance, in metres. Small enough to be invisible at the near plane.
const SIZE := 0.0005

var _items: Array = []
var _seen := {}
var _drawn := 0
var _started := false
var _done := false
var _start_msec := 0
var _quad: QuadMesh = null


## Every [Material] and [Mesh] a subtree draws: geometry's surface and override materials,
## and particles' process and draw-pass materials. [param into] dedupes across calls.
static func collect(root: Node, into: Array = []) -> Array:
	if root == null:
		return into
	var seen := {}
	for item: Variant in into:
		seen[item] = true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var found: Array = []
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.mesh != null:
				found.append(mi.mesh)
				for i in mi.mesh.get_surface_count():
					found.append(mi.get_active_material(i))
		if node is GeometryInstance3D:
			found.append((node as GeometryInstance3D).material_override)
			found.append((node as GeometryInstance3D).material_overlay)
		if node is GPUParticles3D:
			var gp := node as GPUParticles3D
			found.append(gp.process_material)
			for i in gp.draw_passes:
				found.append(gp.get_draw_pass_mesh(i))
		elif node is CPUParticles3D:
			found.append((node as CPUParticles3D).mesh)
		for item: Variant in found:
			if item != null and not seen.has(item):
				seen[item] = true
				into.append(item)
	return into


## Queues [Material]s, [Mesh]es and [ParticleProcessMaterial]s (anything else is ignored).
## Call before [method start].
func add_items(items: Array) -> void:
	for item: Variant in items:
		if (item is Material or item is Mesh) and not _seen.has(item):
			_seen[item] = true
			_items.append(item)


func item_count() -> int:
	return _items.size()


## Puts every item in front of the parent camera (or wherever this node is) and starts
## counting frames. Called with nothing queued, it finishes on the next frame.
func start() -> void:
	if _started:
		return
	_started = true
	_start_msec = Time.get_ticks_msec()
	var cam := get_parent() as Camera3D
	var near := cam.near if cam != null else 0.05
	# Just past the near plane, centred: inside every frustum, behind nothing.
	position = Vector3(0.0, 0.0, -(near + 0.01))
	_quad = QuadMesh.new()
	_quad.size = Vector2(SIZE, SIZE)
	var i := 0
	for item: Variant in _items:
		var node := _instance_for(item)
		if node == null:
			continue
		# Spread a little so no two share a depth (a renderer may skip one fully hidden
		# behind another of the same pass); still well under a pixel apart.
		node.position = Vector3(float(i & 7) * SIZE, float((i >> 3) & 7) * SIZE, -float(i >> 6) * SIZE)
		add_child(node)
		i += 1
	var _c := RenderingServer.frame_post_draw.connect(_on_drawn)
	DotLog.debug(CHANNEL, "warming %d materials and meshes" % i, {"items": i})


func _instance_for(item: Variant) -> Node3D:
	if item is ParticleProcessMaterial or (item is ShaderMaterial and (item as ShaderMaterial).shader != null and (item as ShaderMaterial).shader.get_mode() == Shader.MODE_PARTICLES):
		var gp := GPUParticles3D.new()
		gp.process_material = item
		gp.amount = 1
		gp.draw_pass_1 = _quad
		gp.emitting = true
		gp.visibility_aabb = AABB(Vector3.ONE * -0.01, Vector3.ONE * 0.02)
		return gp
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if item is Mesh:
		var mesh := item as Mesh
		mi.mesh = mesh
		# A mesh is drawn as itself (its vertex format is part of the variant), shrunk to
		# the same size as a quad.
		var extent := mesh.get_aabb().get_longest_axis_size()
		var k := SIZE / maxf(extent, 0.001)
		mi.scale = Vector3(k, k, k)
		mi.position -= mesh.get_aabb().get_center() * k
		return mi
	if item is Material:
		mi.mesh = _quad
		mi.material_override = item
		return mi
	return null


func _process(_delta: float) -> void:
	# Never drawn (headless, a hidden window): give up rather than hold a cover up.
	if _started and not _done and Time.get_ticks_msec() - _start_msec > int(timeout_sec * 1000.0):
		_finish()
	elif _started and not _done and _items.is_empty() and Time.get_ticks_msec() > _start_msec:
		_finish()


func _on_drawn() -> void:
	_drawn += 1
	if _drawn >= frames:
		_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	if RenderingServer.frame_post_draw.is_connected(_on_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_drawn)
	var n := get_child_count()
	finished.emit(n)
	queue_free()


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_drawn)


func describe() -> Dictionary:
	return {"items": _items.size(), "started": _started, "drawn_frames": _drawn, "done": _done}
