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
## half the budget, and each next round is sized from the measured draw cost per item, up to [member batch_size].
## A count alone cannot bound a frame: one first-draw compile costs far more than another, so an item is priced at
## the dearer of the last round's mean and the dearest seen lately (halved by each round that kept to the budget),
## and a round grows at most [member growth] times the last. One item dearer than the budget still takes its
## frame: nothing splits a compile.
@export var budget_msec: float = 0.0

## Seconds without a drawn frame after which [signal finished] fires anyway: a headless run or a
## hidden window never draws, and a cover waiting on this must not wait for ever.
@export var timeout_sec: float = 5.0

## Items in the first budgeted round, before any cost has been measured (capped by [member batch_size]). One: an
## unmeasured round of 16 first-draw compiles was a 4.2 s frame in the web shell (staging02, 2026-11-15); later
## rounds grow from the measured cost, by at most [member growth].
@export var first_batch: int = FIRST_BATCH

## Most a budgeted round may grow over the last, as a factor. Cheap rounds (pipelines already compiled) make the
## per-item estimate tiny, and a round sized from that alone can land on a run of uncompiled ones. 0 = no limit.
@export var growth: float = GROWTH

## What each round that kept to the budget leaves of the dearest per-item cost seen, from 0 (forget it at once) to 1
## (hold it for good: once one item outran the budget, every later round is one item, so no frame holds two
## compiles). Below 1 trades frame bound for pace: in the web shell, decay 0.5 let a run of cheap rounds forget a
## 1.4 s compile and grow to a 32-item, 2.7 s round (staging02, 2026-11-15). Under a loading screen pace matters
## more; in play, hold it.
@export var dear_decay: float = DEAR_DECAY

## Skips an item whose pipeline [method item_key] says another queued item already compiles: a scene's hundreds of
## [BaseMaterial3D]s collapse to the few dozen distinct shaders, and drawing the second of a pair compiles nothing.
## Anything [method item_key] cannot key (a particle process material) is always kept. Off draws every item.
@export var dedupe: bool = true

## Draws the items that cost most to compile first, by [method item_cost]. The rounds start at [member first_batch]
## and double, so the dear compiles land in the small early rounds, where one dear item is a small round, and the
## cheap bulk fills the large later ones. Equal estimates keep their queue order. Off (the default: software-GL A/B 2026-11-15 showed no gain beyond noise) draws in queue order.
@export var dear_first: bool = false

## Default [member first_batch].
const FIRST_BATCH := 1
## Default [member growth].
const GROWTH := 2.0
## Default [member dear_decay].
const DEAR_DECAY := 0.5
## Fewest items a budgeted round places. One: a round must make progress, and each further item dearer than the
## budget is another budget's worth over it.
const MIN_BATCH := 1

## Side of each instance, in metres. Small enough to be invisible at the near plane.
const SIZE := 0.0005

var _items: Array = []
var _seen := {}
var _keys := {}  # pipeline key -> true, for the items queued
var _key_cache := {}  # material instance id -> key
var _skipped := 0  # items dropped as another's pipeline
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
var _dear_usec := 0.0  # dearest per-item cost seen lately; halved by each round that kept to the budget
var _longest_usec := 0  # dearest round's first frame
var _longest_items := 0  # and the items it held
var _over_rounds := 0  # rounds whose first frame passed the budget
var _frames_total := 0  # frames drawn since start

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
			if dedupe:
				var key := item_key(item, _key_cache)
				if key != "":
					if _keys.has(key):
						_skipped += 1
						continue
					_keys[key] = true
			_items.append(item)


## What decides the pipeline [param item] compiles. A [BaseMaterial3D]: its class, every int and bool property and
## which textures it has (a superset of the engine's own shader key). A [ShaderMaterial]: its shader (uniform values
## compile nothing). A [Mesh]: each surface's primitive, vertex format and material key. "" for anything else
## (a particle process material, a mesh with a material it cannot key): never merged. [param cache] holds material
## keys by instance id across calls.
static func item_key(item: Variant, cache: Dictionary = {}) -> String:
	if item is BaseMaterial3D:
		return _material_key(item as BaseMaterial3D, cache)
	if item is ShaderMaterial:
		var sm := item as ShaderMaterial
		if sm.shader == null:
			return ""
		var next := ""
		if sm.next_pass != null:
			next = item_key(sm.next_pass, cache)
			if next == "":
				return ""
		return "shader:%d;next=%s" % [sm.shader.get_instance_id(), next]
	if item is Mesh:
		var mesh := item as Mesh
		var parts := PackedStringArray([mesh.get_class(), "shapes%d" % (mesh as ArrayMesh).get_blend_shape_count() if mesh is ArrayMesh else 0])
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			var mat_key := "default" if mat == null else item_key(mat, cache)
			if mat_key == "":
				return ""
			parts.append("%s/%s" % [_surface_layout(mesh, i), mat_key])
		return "mesh:" + "#".join(parts)
	return ""


## The vertex layout and primitive of one surface: an [ArrayMesh]'s own format and primitive; any other mesh (a
## [PrimitiveMesh]) by which vertex arrays it fills, its class fixing the primitive.
static func _surface_layout(mesh: Mesh, surface: int) -> String:
	if mesh is ArrayMesh:
		var am := mesh as ArrayMesh
		return "%d/%d" % [am.surface_get_primitive_type(surface), am.surface_get_format(surface)]
	var arrays := mesh.surface_get_arrays(surface)
	var filled := ""
	for i in arrays.size():
		filled += "1" if arrays[i] != null and arrays[i].size() > 0 else "0"
	return "arrays" + filled


static func _material_key(mat: BaseMaterial3D, cache: Dictionary) -> String:
	var id := mat.get_instance_id()
	if cache.has(id):
		return cache[id]
	var parts := PackedStringArray([mat.get_class()])
	for prop: Dictionary in mat.get_property_list():
		if not int(prop["usage"]) & PROPERTY_USAGE_STORAGE:
			continue
		var name: String = prop["name"]
		match int(prop["type"]):
			TYPE_BOOL, TYPE_INT:
				parts.append("%s=%s" % [name, mat.get(name)])
			TYPE_OBJECT:
				if name != "next_pass":
					parts.append("%s=%s" % [name, mat.get(name) != null])
	var next := mat.next_pass
	if next != null:
		var next_key := item_key(next, cache)
		parts.append("next=" + (next_key if next_key != "" else "id%d" % next.get_instance_id()))
	var key := "mat:" + ";".join(parts)
	cache[id] = key
	return key


## A relative estimate of what [param item] costs the frame that first draws it (no unit, only the order matters).
## A particle process material compiles a transform-feedback program, a [ShaderMaterial] a whole shader (longer code,
## more cost), a [BaseMaterial3D] by the features that grow its shader, a mesh only its vertex format's pipeline.
static func item_cost(item: Variant) -> float:
	if item is ParticleProcessMaterial:
		return 40.0
	if item is ShaderMaterial:
		var sm := item as ShaderMaterial
		var cost := 20.0
		if sm.shader != null:
			cost += float(sm.shader.code.length()) / 200.0
			if sm.shader.get_mode() == Shader.MODE_PARTICLES:
				cost += 20.0
		if sm.next_pass != null:
			cost += item_cost(sm.next_pass)
		return cost
	if item is BaseMaterial3D:
		var mat := item as BaseMaterial3D
		var cost := 4.0
		for prop: Dictionary in mat.get_property_list():
			if int(prop["type"]) == TYPE_OBJECT and int(prop["usage"]) & PROPERTY_USAGE_STORAGE \
					and prop["name"] != "next_pass" and mat.get(prop["name"]) != null:
				cost += 1.0
		if mat.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL:
			cost += 2.0
		if mat.next_pass != null:
			cost += item_cost(mat.next_pass)
		return cost
	if item is Mesh:
		return 2.0
	return 1.0


func item_count() -> int:
	return _items.size()


## Items [method add_items] dropped because another queued item compiles the same pipeline.
func skipped_count() -> int:
	return _skipped


## Puts every item in front of the parent camera (or wherever this node is) and starts
## counting frames. Called with nothing queued, it finishes on the next frame.
func start() -> void:
	if _started:
		return
	_started = true
	_start_msec = Time.get_ticks_msec()
	if dear_first:
		_order_by_cost()
	var cam := get_parent() as Camera3D
	var near := cam.near if cam != null else 0.05
	# Just past the near plane, centred: inside every frustum, behind nothing.
	position = Vector3(0.0, 0.0, -(near + 0.01))
	_quad = QuadMesh.new()
	_quad.size = Vector2(SIZE, SIZE)
	if growth < 0.0 or (growth > 0.0 and growth < 1.0):
		DotLog.warn(CHANNEL, "growth %.2f cannot grow a round; use 1 or more, or 0 for no limit" % growth, {"growth": growth})
	if dear_decay < 0.0 or dear_decay > 1.0:
		DotLog.warn(CHANNEL, "dear_decay %.2f is outside 0..1; 0 forgets a dear item at once, 1 holds it" % dear_decay, {"dear_decay": dear_decay})
	var _c := RenderingServer.frame_post_draw.connect(_on_drawn)
	var first := maxi(first_batch, 1)
	_cap = first if batch_size <= 0 else mini(first, batch_size)
	_draw_usec = Time.get_ticks_usec()
	_place_batch()
	DotLog.debug(CHANNEL, "warming %d materials and meshes" % _items.size(), {"items": _items.size(), "batch": batch_size, "budget_msec": budget_msec})


## Sorts the queue by [method item_cost], dearest first, equal costs in queue order.
func _order_by_cost() -> void:
	var rows: Array = []
	for i in _items.size():
		rows.append([item_cost(_items[i]), i])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var sorted: Array = []
	for row: Array in rows:
		sorted.append(_items[row[1]])
	_items = sorted


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
		if _first_cost_usec > _longest_usec:
			_longest_usec = _first_cost_usec
			_longest_items = _round_placed
		if budget_msec > 0.0 and _first_cost_usec > int(budget_msec * 1000.0):
			_over_rounds += 1
	elif _base_usec < 0 or now - _draw_usec < _base_usec:
		_base_usec = now - _draw_usec
	_draw_usec = now
	_drawn += 1
	_frames_total += 1
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
## what its items cost, and the budget less that frame is the room they get. Each item is priced at the
## dearer of that mean and the dearest seen lately, so one cheap round cannot size the next for a run of compiles.
func _resize() -> void:
	if _round_placed <= 0:
		return
	var base := maxi(_base_usec, 0)
	# A device whose bare frame already passes the budget still gives the warm-up half of it, or one item a
	# round would be the whole pace.
	var room := maxf(budget_msec * 1000.0 - float(base), budget_msec * 500.0)
	var cost := float(_first_cost_usec - base)
	var mean := maxf(cost / float(_round_placed), 1.0)
	if cost > room:
		_dear_usec = maxf(_dear_usec, mean)
	else:
		_dear_usec *= dear_decay
	var per_item := maxf(mean, _dear_usec)
	var n := int(room / per_item)
	if growth > 0.0:
		n = mini(n, int(float(_round_placed) * growth))
	_cap = maxi(n, MIN_BATCH)
	if batch_size > 0:
		_cap = mini(_cap, batch_size)


func _finish() -> void:
	if _done:
		return
	_done = true
	if RenderingServer.frame_post_draw.is_connected(_on_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_drawn)
	# A renderer that drew and then stopped (a hidden tab) leaves items to compile in play; headless never drew.
	if _frames_total > 0 and left() > 0:
		DotLog.warn(CHANNEL, "warm-up timed out with %d of %d items never drawn; they will compile on first use" % [left(), _items.size()], describe())
	finished.emit(_placed)
	queue_free()


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_drawn)
	# Freed before its last round went up (its camera went away): those items compile on first use instead.
	if _started and not _done and left() > 0:
		DotLog.warn(CHANNEL, "warm-up freed with %d of %d items never drawn; they will compile on first use" % [left(), _items.size()], describe())


## Items not put up yet.
func left() -> int:
	return _items.size() - _next


func describe() -> Dictionary:
	return {"items": _items.size(), "deduped": _skipped, "started": _started, "drawn_frames": _drawn, "done": _done, "rounds": _rounds, "placed": _placed, "left": left(), "budget_msec": budget_msec, "longest_round_ms": snappedf(_longest_usec / 1000.0, 0.1), "longest_round_items": _longest_items, "over_budget_rounds": _over_rounds}
