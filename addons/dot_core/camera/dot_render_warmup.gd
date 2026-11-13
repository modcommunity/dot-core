class_name DotRenderWarmup
extends Node3D

## Draws every material a scene will need once, out of sight, so shaders compile under a cover (the
## Compatibility renderer compiles synchronously on first draw). Items sit on a tiny instance past the near plane.
## Variants it cannot reach (skinned, later lights) still stall. Use: [code]add_items(collect(level))[/code], [code]start()[/code], await [signal finished].

const CHANNEL := "dot.render_warmup"

## Emitted once the items have been drawn for [member frames] frames and removed.
signal finished(count: int)

## Frames the items stay up. Two: the first draw compiles, and a renderer that compiles a
## shadow or depth variant a frame later gets its second chance.
@export var frames: int = 2

## Items put up per round (each round stays [member frames] frames). One round of thousands is a
## single frame of seconds that no cover can animate through and a desktop calls "not responding".
## 0 draws everything at once.
@export var batch_size: int = 1000

## Milliseconds a round may cost its frame. Above 0, rounds start at [member first_batch] items, placing stops at
## half the budget, and each next round is sized from the last one's measured draw cost per item, up to
## [member batch_size]. A count alone cannot bound a frame: one first-draw compile costs far more than another.
@export var budget_msec: float = 0.0

## Seconds without a drawn frame after which [signal finished] fires anyway: a headless run or a
## hidden window never draws, and a cover waiting on this must not wait for ever.
@export var timeout_sec: float = 5.0

## Items in the first budgeted round, before any cost has been measured (capped by [member batch_size]). A warm-up whose
## items each compile a pipeline (a new level's materials) starts smaller, 1-4, so the unmeasured round cannot be the
## longest frame; later rounds still grow from the measured cost, up to four times the last.
@export var first_batch: int = FIRST_BATCH

## Default [member first_batch].
const FIRST_BATCH := 16
## Fewest items a budgeted round places, so a frame slow for other reasons cannot stretch the warm-up out.
const MIN_BATCH := 4

## Side of each instance, in metres. Small enough to be invisible at the near plane.
const SIZE := 0.0005

var _items: Array = []
var _seen := {}
var _drawn := 0
var _next := 0
var _placed := 0
var _started := false
var _done := false
var _start_msec := 0
var _quad: QuadMesh = null
var _proxied := {}
var _rounds := 0
var _cap := 0  # items the next budgeted round places
var _round_placed := 0
var _round_usec := 0  # when the current round was placed
var _draw_usec := 0  # the last frame_post_draw
var _first_cost_usec := 0  # placing to first draw of the current round
var _base_usec := -1  # cheapest frame with nothing new placed: the frame without the warm-up

## A mesh with more surfaces than this is drawn as one triangle per distinct material and
## vertex format, not as itself: a converted map is thousands of meshes, so drawing each
## was a ~18000-call frame. Zero: every mesh is warmed once per pipeline.
const PROXY_SURFACES := 0


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
	var _c := RenderingServer.frame_post_draw.connect(_on_drawn)
	var first := maxi(first_batch, 1)
	_cap = first if batch_size <= 0 else mini(first, batch_size)
	_draw_usec = Time.get_ticks_usec()
	_place_batch()
	DotLog.debug(CHANNEL, "warming %d materials and meshes" % _items.size(), {"items": _items.size(), "batch": batch_size, "budget_msec": budget_msec})


## Rounds the items are drawn in. With [member budget_msec] the size follows the measured cost,
## so this is the rounds placed so far.
func batch_count() -> int:
	if budget_msec > 0.0:
		return maxi(_rounds, 1)
	if batch_size <= 0 or _items.is_empty():
		return 1
	return ceili(float(_items.size()) / float(batch_size))


## Puts the next round up and returns how many were placed: [member batch_size] items, or under a
## budget, [member _cap] instances or half the budget's time, whichever comes first.
func _place_batch() -> int:
	var budgeted := budget_msec > 0.0
	var end := _items.size() if batch_size <= 0 or budgeted else mini(_next + batch_size, _items.size())
	var t0 := Time.get_ticks_usec()
	var stop_usec := t0 + int(budget_msec * 500.0)
	_round_usec = t0
	_rounds += 1
	var i := 0
	while _next < end:
		if budgeted and i > 0 and (i >= _cap or Time.get_ticks_usec() > stop_usec):
			break
		var node := _instance_for(_items[_next])
		_next += 1
		if node == null:
			continue
		# Spread a little so no two share a depth (a renderer may skip one fully hidden
		# behind another of the same pass); still well under a pixel apart.
		node.position = Vector3(float(i & 7) * SIZE, float((i >> 3) & 7) * SIZE, -float(i >> 6) * SIZE)
		add_child(node)
		i += 1
	_placed += i
	_round_placed = i
	return i


func _instance_for(item: Variant) -> Node3D:
	if item is ParticleProcessMaterial or (item is ShaderMaterial and (item as ShaderMaterial).shader != null and (item as ShaderMaterial).shader.get_mode() == Shader.MODE_PARTICLES):
		var gp := GPUParticles3D.new()
		gp.process_material = item
		gp.amount = 1
		gp.draw_pass_1 = _quad
		gp.emitting = true
		gp.visibility_aabb = AABB(Vector3.ONE * -0.01, Vector3.ONE * 0.02)
		return gp
	# The instance is made only once there is something to draw: one made and then dropped would
	# be an orphan node for the life of the process (420 per world build in mg-wipeout).
	if item is Mesh:
		var mesh := item as Mesh
		if mesh.get_surface_count() > PROXY_SURFACES:
			mesh = _proxy_for(mesh)
			if mesh == null:
				return null
		var mi := _new_instance()
		mi.mesh = mesh
		# A mesh is drawn as itself (its vertex format is part of the variant), shrunk to
		# the same size as a quad.
		var extent := mesh.get_aabb().get_longest_axis_size()
		var k := SIZE / maxf(extent, 0.001)
		mi.scale = Vector3(k, k, k)
		mi.position -= mesh.get_aabb().get_center() * k
		return mi
	if item is Material:
		var mi := _new_instance()
		mi.mesh = _quad
		mi.material_override = item
		return mi
	return null


func _new_instance() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi


## One triangle of each surface whose (material, vertex format) has not been drawn yet, in the
## surface's own format so its pipeline is the one the full mesh will use. Null if nothing is new.
func _proxy_for(source: Mesh) -> ArrayMesh:
	var mesh := source
	if not (source is ArrayMesh):
		# A primitive mesh has no surface format; an array copy of it does.
		var copy := ArrayMesh.new()
		for i in source.get_surface_count():
			copy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(i))
			copy.surface_set_material(i, source.surface_get_material(i))
		mesh = copy
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var fmt: int = mesh.surface_get_format(i)
		var mat := mesh.surface_get_material(i)
		var key := [mat.get_instance_id() if mat != null else 0, fmt]
		if _proxied.has(key):
			continue
		var arrays := _first_triangle(mesh.surface_get_arrays(i))
		if arrays.is_empty():
			continue
		_proxied[key] = true
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt & ~Mesh.ARRAY_FORMAT_INDEX)
		out.surface_set_material(out.get_surface_count() - 1, mat)
	return out if out.get_surface_count() > 0 else null


## The first triangle of a surface's arrays, every per-vertex array cut to its three vertices and
## moved to the origin; empty when the surface has fewer than three.
static func _first_triangle(arrays: Array) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var count := verts.size()
	if count < 3:
		return []
	var picks: Array[int] = [0, 1, 2]
	var index: Variant = arrays[Mesh.ARRAY_INDEX]
	if index != null and (index as PackedInt32Array).size() >= 3:
		var idx := index as PackedInt32Array
		picks = [idx[0], idx[1], idx[2]]
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	for k in Mesh.ARRAY_MAX:
		var src: Variant = arrays[k]
		if src == null or k == Mesh.ARRAY_INDEX or (src as Variant).size() == 0:
			continue
		var stride: int = (src as Variant).size() / count
		var cut: Variant = src.slice(0, 0)
		for v in picks:
			cut.append_array(src.slice(v * stride, (v + 1) * stride))
		out[k] = cut
	var base: Vector3 = verts[picks[0]]
	var moved := PackedVector3Array()
	for v in picks:
		moved.append(verts[v] - base)
	out[Mesh.ARRAY_VERTEX] = moved
	return out


func _process(_delta: float) -> void:
	# Never drawn (headless, a hidden window): give up rather than hold a cover up.
	if _started and not _done and Time.get_ticks_msec() - _start_msec > int(timeout_sec * 1000.0):
		_finish()
	elif _started and not _done and _items.is_empty() and Time.get_ticks_msec() > _start_msec:
		_finish()


func _on_drawn() -> void:
	_start_msec = Time.get_ticks_msec()
	var now := Time.get_ticks_usec()
	if _drawn == 0:
		_first_cost_usec = now - _round_usec
	elif _base_usec < 0 or now - _draw_usec < _base_usec:
		_base_usec = now - _draw_usec
	_draw_usec = now
	_drawn += 1
	if _drawn < frames:
		return
	if _next >= _items.size():
		_finish()
		return
	_drawn = 0
	for child in get_children():
		child.queue_free()
	if budget_msec > 0.0:
		_resize()
	_place_batch()


## Sizes the next budgeted round from the last: its first frame less the cheapest frame seen is
## what its items cost, and the budget less that frame is the room they get.
func _resize() -> void:
	if _round_placed <= 0:
		return
	var base := maxi(_base_usec, 0)
	var per_item := maxf(float(_first_cost_usec - base) / float(_round_placed), 1.0)
	var room := budget_msec * 1000.0 - float(base)
	var n := int(room / per_item) if room > 0.0 else MIN_BATCH
	_cap = clampi(n, MIN_BATCH, maxi(_round_placed * 4, MIN_BATCH))
	if batch_size > 0:
		_cap = mini(_cap, batch_size)


func _finish() -> void:
	if _done:
		return
	_done = true
	if RenderingServer.frame_post_draw.is_connected(_on_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_drawn)
	finished.emit(_placed)
	queue_free()


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_drawn)


func describe() -> Dictionary:
	return {"items": _items.size(), "started": _started, "drawn_frames": _drawn, "done": _done, "rounds": _rounds, "placed": _placed, "budget_msec": budget_msec}
