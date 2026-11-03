class_name DotCameraBoom
extends Node3D

## A third-person camera mount that stays out of the level: `SpringArm3D`'s four names
## ([member spring_length], [member margin], [member collision_mask], [method add_excluded_object]).
## Origin is the pivot, +Z where the camera sits; children are placed each frame ([method force_update] cuts). See docs/camera.md.

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

## Metres straight up (world up) added to where the camera wants to be, swept from a pivot at the eye:
## a pivot raised above the head can itself be inside a low beam, and a sweep that starts inside
## geometry does not see it.
@export var lift: float = 0.0

## Layers the camera stops against.
@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		collision_mask = value
		if probe != null:
			probe.collision_mask = value

## Whether the boom places its children itself, once a frame. A rig that moves the pivot
## and wants the camera placed in the same call sets this false and calls [method place].
@export var auto_place: bool = true

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
## Excludes every collision object from here up to the root: the body a rig hangs off, walked
## rather than handed over, for a rig built before its body is known.
func exclude_ancestors() -> void:
	var node: Node = get_parent()

	while node != null:
		var body := node as CollisionObject3D

		if body != null:
			probe.add_excluded_object(body.get_rid())

		node = node.get_parent()


## Where the camera would be with nothing in the way, in the boom's space (without
## [member lift], which is the world's up).
func wanted_local() -> Vector3:
	return Vector3(side_offset, 0.0, spring_length)


## Where the camera would be with nothing in the way, in the world.
func wanted_global() -> Vector3:
	return global_transform * wanted_local() + Vector3.UP * lift


## The current length of the boom, after the level has pulled it in.
func get_hit_length() -> float:
	return _length


func _process(delta: float) -> void:
	if auto_place:
		place(delta)


## Places the children now, without easing: after a cut.
func force_update() -> void:
	probe.reset()
	place(0.0)


## Places the children for a frame of [param delta] seconds. Called by the boom itself
## unless [member auto_place] is off.
func place(delta: float) -> void:
	if not is_inside_tree():
		return

	if probe.world == null:
		probe.world = get_world_3d()

	var pivot := global_position
	var wanted := wanted_global()

	if pivot.distance_to(wanted) < 0.0001:
		_length = 0.0
		_set_children(Vector3.ZERO)
		return

	var got := probe.resolve(pivot, wanted, delta)
	_length = pivot.distance_to(got)
	_set_children(global_transform.affine_inverse() * got)


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
