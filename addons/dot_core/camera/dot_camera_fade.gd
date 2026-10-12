class_name DotCameraFade
extends Node

## Fades characters that come between a camera and what it is looking at, and hides one
## that walks into the camera itself.
##
## [codeblock]
## var fade := DotCameraFade.new()
## fade.collision_mask = layout.layer_mask(&"player") | layout.layer_mask(&"npc")
## fade.add_excluded_object(player.get_rid())
## camera.add_child(fade)          # it follows its parent camera
##
## fade.focus = boom               # third person: what the camera looks at
## fade.focus = null               # first person: only the near test
## [/codeblock]
##
## [b]Two tests, once a frame.[/b] A sphere of [member near] round the camera: anything in
## it is a body the near plane is about to cut, and goes fully transparent (the play
## test's "a face fills the screen"). And, in third person, a capsule along the line from
## the camera to [member focus], stopped short of the focus so the watched character is
## never in it: anything there goes to [member faded], seen through rather than gone,
## because a player wants to know somebody is standing there.
##
## [b]Characters are faded, not collided with.[/b] A camera that stopped against every
## body would pull into the player's head each time a bot walked behind them, and a crowd
## would pin it there. [DotCameraProbe] stops against the level; this deals with people.
##
## [b]What fades is every [GeometryInstance3D] under the body that was hit[/b], by its
## `transparency`, which every renderer honours — or under whatever [member root_fn]
## names, for a game whose drawn figure is not a child of its collider. A [Camera3D] in
## that subtree is skipped with everything under it: a first-person camera parented to a
## body carries the view model, and fading somebody's body must not fade their gun.

## Layers whose bodies fade: characters, never the level.
@export_flags_3d_physics var collision_mask: int = 0

## What the camera looks at. Null: only the near test runs.
var focus: Node3D = null

## Metres round the camera inside which a body is hidden outright.
@export var near: float = 0.25

## Radius of the line between the camera and the focus.
@export var line_radius: float = 0.25

## The line stops this far short of the focus, so the watched body is not on it.
@export var focus_clearance: float = 0.6

## How transparent a body on the line goes (0 opaque, 1 gone).
@export_range(0.0, 1.0) var faded: float = 0.7

## Seconds for a fade to go about two-thirds of the way.
@export var fade_time: float = 0.08

## [code](collider: Object) -> Node[/code]: whose meshes fade for a hit. Default: the
## collider itself.
var root_fn: Callable = Callable()

## [code]() -> Array[/code] of [Node3D]s: characters that are not in the physics space at
## all (a game whose players collide analytically, or whose remote figures have no
## collider on a client). Each is taken as an upright capsule of [member body_radius] and
## [member body_height] standing on its origin, and its own meshes fade. Used as well as
## [member collision_mask], not instead.
var bodies_fn: Callable = Callable()

## The capsule [member bodies_fn]'s characters are taken as.
@export var body_radius: float = 0.35
@export var body_height: float = 1.8

var _excluded: Array[RID] = []
# instance id -> {"root": WeakRef, "meshes": Array, "amount": float, "target": float}
var _fading: Dictionary = {}
var _near_shape: SphereShape3D = null
var _line_shape: CapsuleShape3D = null


func _init() -> void:
	# After the camera has been placed for the frame, whatever placed it.
	process_priority = 1000


func add_excluded_object(rid: RID) -> void:
	if rid.is_valid() and not _excluded.has(rid):
		_excluded.append(rid)


func remove_excluded_object(rid: RID) -> void:
	_excluded.erase(rid)


func clear_excluded_objects() -> void:
	_excluded.clear()


func _process(delta: float) -> void:
	var camera := get_parent() as Node3D

	if camera == null or not camera.is_inside_tree():
		return

	var to := camera.global_position

	if focus != null and is_instance_valid(focus) and focus.is_inside_tree():
		to = focus.global_position

	update(camera.global_position, to, delta)


## One frame's fade, for a caller placing its own camera without this node's parent.
## Returns how many bodies are faded or fading.
func update(camera_position: Vector3, focus_position: Vector3, delta: float) -> int:
	var world := _world()
	var wanted: Dictionary = {}

	if world != null and collision_mask != 0:
		var space := world.direct_space_state

		for collider in _near(space, camera_position):
			wanted[collider] = 1.0

		for collider in _line(space, camera_position, focus_position):
			if not wanted.has(collider):
				wanted[collider] = faded

	if bodies_fn.is_valid():
		_analytic(camera_position, focus_position, wanted)

	if wanted.is_empty() and _fading.is_empty():
		return 0

	for collider in wanted:
		_target(collider as Object, float(wanted[collider]))

	for key in _fading.keys():
		var entry: Dictionary = _fading[key]

		if not wanted.has(entry.get("collider")):
			entry["target"] = 0.0

	return _step(delta)


## Puts every faded body back as it was. Call on leaving, or when the camera stops being
## this player's.
func release() -> void:
	for key in _fading.keys():
		_apply(_fading[key], 0.0)

	_fading.clear()


func _exit_tree() -> void:
	release()


## The same two tests against upright capsules, for characters with no collider.
func _analytic(camera_position: Vector3, focus_position: Vector3, wanted: Dictionary) -> void:
	var offset := focus_position - camera_position
	var length := offset.length() - focus_clearance
	var line_end := camera_position + offset.normalized() * maxf(length, 0.0)

	for node in bodies_fn.call():
		var body := node as Node3D

		if body == null or not is_instance_valid(body) or not body.is_inside_tree() or not body.visible:
			continue

		var feet := body.global_position
		var low := feet + Vector3.UP * body_radius
		var high := feet + Vector3.UP * maxf(body_height - body_radius, body_radius)
		var on_axis := Geometry3D.get_closest_point_to_segment(camera_position, low, high)

		if on_axis.distance_to(camera_position) < near + body_radius:
			wanted[body] = 1.0
			continue

		if length <= line_radius * 2.0:
			continue

		var pair := Geometry3D.get_closest_points_between_segments(camera_position, line_end, low, high)

		if (pair[0] as Vector3).distance_to(pair[1] as Vector3) < line_radius + body_radius:
			wanted[body] = faded


func _near(space: PhysicsDirectSpaceState3D, at: Vector3) -> Array:
	if near <= 0.0:
		return []

	if _near_shape == null:
		_near_shape = SphereShape3D.new()

	_near_shape.radius = near
	return _colliders(space, _near_shape, Transform3D(Basis.IDENTITY, at))


func _line(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Array:
	var offset := to - from
	var length := offset.length() - focus_clearance

	if length <= line_radius * 2.0:
		return []

	var direction := offset.normalized()

	if _line_shape == null:
		_line_shape = CapsuleShape3D.new()

	_line_shape.radius = line_radius
	_line_shape.height = length

	# A capsule stands along its local Y; turn Y onto the line, and centre it on the part
	# of the line that is not the focus's clearance.
	var y := direction
	var x := y.cross(Vector3.UP)

	if x.length_squared() < 0.0001:
		x = y.cross(Vector3.RIGHT)

	x = x.normalized()
	var z := x.cross(y).normalized()
	var centre := from + direction * (length * 0.5)

	return _colliders(space, _line_shape, Transform3D(Basis(x, y, z), centre))


func _colliders(space: PhysicsDirectSpaceState3D, shape: Shape3D, at: Transform3D) -> Array:
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = at
	params.collision_mask = collision_mask
	params.exclude = _excluded
	params.collide_with_areas = false

	var out: Array = []

	for hit in space.intersect_shape(params, 16):
		var collider: Object = (hit as Dictionary).get("collider")

		if collider != null and not out.has(collider):
			out.append(collider)

	return out


func _target(collider: Object, amount: float) -> void:
	var root: Node = collider as Node

	if root_fn.is_valid():
		root = root_fn.call(collider) as Node

	if root == null:
		return

	var key := root.get_instance_id()
	var entry: Dictionary = _fading.get(key, {})

	if entry.is_empty():
		entry = {"root": weakref(root), "meshes": [], "ids": {}, "amount": 0.0, "collider": collider}
		_fading[key] = entry

	# Collected again on every frame it is hit, merged: a figure that rebuilt its avatar
	# while faded has new meshes, and the old ones still have to be put back.
	var ids: Dictionary = entry["ids"]

	for ref in _meshes(root):
		var id := (ref as WeakRef).get_ref().get_instance_id() as int

		if not ids.has(id):
			ids[id] = true
			(entry["meshes"] as Array).append(ref)
			((ref as WeakRef).get_ref() as GeometryInstance3D).transparency = float(entry["amount"])

	entry["collider"] = collider
	entry["target"] = amount


func _step(delta: float) -> int:
	var factor := 1.0 - exp(-maxf(delta, 0.0) / maxf(fade_time, 0.001))

	for key in _fading.keys():
		var entry: Dictionary = _fading[key]

		if (entry["root"] as WeakRef).get_ref() == null:
			_fading.erase(key)
			continue

		var target := float(entry.get("target", 0.0))
		var amount := lerpf(float(entry["amount"]), target, factor)

		if absf(amount - target) < 0.01:
			amount = target

		_apply(entry, amount)

		if amount <= 0.0 and target <= 0.0:
			_fading.erase(key)

	return _fading.size()


func _apply(entry: Dictionary, amount: float) -> void:
	entry["amount"] = amount
	var hidden: Dictionary = entry.get("hidden", {})
	entry["hidden"] = hidden

	for ref in entry["meshes"]:
		var mesh := (ref as WeakRef).get_ref() as GeometryInstance3D

		if mesh == null:
			continue

		mesh.transparency = amount

		# Fully faded is also not drawn. `transparency` alone left an unshaded figure drawn
		# as a grey slab at 1.0 (mg-wipeout's stand-ins at the lens); only what this fade hid
		# is shown again, so a mesh the game hid stays hidden.
		var id := mesh.get_instance_id()
		if amount >= 0.99 and mesh.visible:
			mesh.visible = false
			hidden[id] = true
		elif amount < 0.99 and hidden.has(id):
			mesh.visible = true
			hidden.erase(id)


static func _meshes(root: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [root]

	while not stack.is_empty():
		var node: Node = stack.pop_back()

		# Somebody's first-person camera carries their view model; leave it alone.
		if node is Camera3D:
			continue

		if node is GeometryInstance3D:
			out.append(weakref(node))

		for child in node.get_children():
			stack.append(child)

	return out


func _world() -> World3D:
	var node := get_parent() as Node3D

	if node != null and node.is_inside_tree():
		return node.get_world_3d()

	return null


## How many bodies are faded or fading now.
func faded_count() -> int:
	return _fading.size()


## Whether this body (or its [member root_fn] root) is faded more than half.
func is_faded(node: Node) -> bool:
	if node == null:
		return false

	var entry: Dictionary = _fading.get(node.get_instance_id(), {})
	return not entry.is_empty() and float(entry["amount"]) > 0.5


func describe() -> Dictionary:
	return {
		"fading": _fading.size(),
		"focus": focus.name if focus != null and is_instance_valid(focus) else "",
		"mask": collision_mask,
		"near": near,
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"camera fade: %d bodies, near %.2f m, %s" % [
			_fading.size(), near, "line to a focus" if focus != null else "near only",
		]
	])
