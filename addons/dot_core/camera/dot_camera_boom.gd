class_name DotCameraBoom
extends Node3D

## A third-person camera mount that stays out of the level: where `SpringArm3D` was, with
## the same four names a game already wrote ([member spring_length], [member margin],
## [member collision_mask], [method add_excluded_object]), so replacing one is a
## constructor and nothing else.
##
## [codeblock]
## var boom := DotCameraBoom.new()
## boom.spring_length = 3.0
## boom.collision_mask = layout.layer_mask(&"world")
## boom.add_excluded_object(player.get_rid())
## boom.position = Vector3(0, eye, 0)      # the pivot: a point that is itself clear
## player.add_child(boom)
## boom.add_child(camera)                  # placed along +Z, like a spring arm's
## [/codeblock]
##
## The boom's origin is the pivot and its +Z the direction the camera sits in, as with a
## spring arm: rotate the boom to orbit. [member side_offset] moves the camera over a
## shoulder, and the sweep runs straight from the pivot to that point, so a shoulder
## against a wall pulls in along the same line instead of putting the near plane through
## it. The sweep and the easing are [DotCameraProbe]'s; read it for why there are two.
##
## Children are placed once a frame at a late priority, after whatever moved the pivot;
## [method force_update] places them now (a cut, a teleport, a test).

## How far behind the pivot the camera wants to be.
@export var spring_length: float = 3.0:
	set(value):
		spring_length = maxf(value, 0.0)

## The camera's radius: how far from any surface it stays.
@export var margin: float = 0.2:
	set(value):
		margin = maxf(value, 0.01)
		if probe != null:
			probe.radius = margin

## Sideways offset of the camera from the line behind the pivot (a shoulder).
@export var side_offset: float = 0.0

## Layers the camera stops against.
@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		collision_mask = value
		if probe != null:
			probe.collision_mask = value

var probe: DotCameraProbe = null

var _length: float = 0.0


func _init() -> void:
	probe = DotCameraProbe.new()
	probe.radius = margin
	probe.collision_mask = collision_mask
	process_priority = 900


func _enter_tree() -> void:
	probe.world = get_world_3d()
	probe.reset()


## Never stop against this body (the player the boom hangs off).
func add_excluded_object(rid: RID) -> void:
	probe.add_excluded_object(rid)


func remove_excluded_object(rid: RID) -> void:
	probe.remove_excluded_object(rid)


func clear_excluded_objects() -> void:
	probe.clear_excluded_objects()


## Excludes every collision object from here up to the root: the body a rig hangs off,
## found by walking rather than handed over, for a rig built before its body is known.
func exclude_ancestors() -> void:
	var node: Node = get_parent()

	while node != null:
		var body := node as CollisionObject3D

		if body != null:
			probe.add_excluded_object(body.get_rid())

		node = node.get_parent()


## Where the camera would be with nothing in the way, in the boom's space.
func wanted_local() -> Vector3:
	return Vector3(side_offset, 0.0, spring_length)


## The current length of the boom, after the level has pulled it in.
func get_hit_length() -> float:
	return _length


func _process(delta: float) -> void:
	_place(delta)


## Places the children now, without easing: after a cut.
func force_update() -> void:
	probe.reset()
	_place(0.0)


func _place(delta: float) -> void:
	if not is_inside_tree():
		return

	var local := wanted_local()
	var full := local.length()

	if full < 0.0001:
		_length = 0.0
		_set_children(Vector3.ZERO)
		return

	if probe.world == null:
		probe.world = get_world_3d()

	var pivot := global_position
	var wanted := global_transform * local
	var got := probe.resolve(pivot, wanted, delta)

	_length = pivot.distance_to(got)
	_set_children(local * (_length / full))


func _set_children(at: Vector3) -> void:
	for child in get_children():
		var node := child as Node3D

		if node != null:
			node.position = at


func describe() -> Dictionary:
	var out := probe.describe()
	out["spring_length"] = spring_length
	out["side_offset"] = side_offset
	out["length"] = _length
	return out


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"camera boom: %.2f of %.2f m, side %+.2f" % [_length, spring_length, side_offset]
	])
