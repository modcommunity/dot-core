class_name DotSpaceQuery
extends RefCounted

## Physics space queries that count and time themselves per calling system while DotFrameCost is enabled,
## and cost one flag check while it is off. [code]DotSpaceQuery.ray(space, q, &"bots")[/code] in place of
## [code]space.intersect_ray(q)[/code]; while tracing, a query nested in a reported span is also charged to that span.

const CAST := &"cast_motion"
const REST := &"rest_info"
const RAY := &"intersect_ray"
const SHAPE := &"intersect_shape"
const POINT := &"intersect_point"
const COLLIDE := &"collide_shape"
const MOVE := &"move_and_collide"
const TEST := &"body_test_motion"


static func cast_motion(space: PhysicsDirectSpaceState3D, q: PhysicsShapeQueryParameters3D, system: StringName = &"") -> PackedFloat32Array:
	if not DotFrameCost.enabled:
		return space.cast_motion(q)
	var t := Time.get_ticks_usec()
	var r := space.cast_motion(q)
	DotFrameCost.add_query(system, CAST, t)
	return r


static func rest_info(space: PhysicsDirectSpaceState3D, q: PhysicsShapeQueryParameters3D, system: StringName = &"") -> Dictionary:
	if not DotFrameCost.enabled:
		return space.get_rest_info(q)
	var t := Time.get_ticks_usec()
	var r := space.get_rest_info(q)
	DotFrameCost.add_query(system, REST, t)
	return r


static func ray(space: PhysicsDirectSpaceState3D, q: PhysicsRayQueryParameters3D, system: StringName = &"") -> Dictionary:
	if not DotFrameCost.enabled:
		return space.intersect_ray(q)
	var t := Time.get_ticks_usec()
	var r := space.intersect_ray(q)
	DotFrameCost.add_query(system, RAY, t)
	return r


static func shape(
	space: PhysicsDirectSpaceState3D, q: PhysicsShapeQueryParameters3D, max_results: int = 32, system: StringName = &""
) -> Array[Dictionary]:
	if not DotFrameCost.enabled:
		return space.intersect_shape(q, max_results)
	var t := Time.get_ticks_usec()
	var r := space.intersect_shape(q, max_results)
	DotFrameCost.add_query(system, SHAPE, t)
	return r


static func point(
	space: PhysicsDirectSpaceState3D, q: PhysicsPointQueryParameters3D, max_results: int = 32, system: StringName = &""
) -> Array[Dictionary]:
	if not DotFrameCost.enabled:
		return space.intersect_point(q, max_results)
	var t := Time.get_ticks_usec()
	var r := space.intersect_point(q, max_results)
	DotFrameCost.add_query(system, POINT, t)
	return r


static func collide_shape(
	space: PhysicsDirectSpaceState3D, q: PhysicsShapeQueryParameters3D, max_results: int = 32, system: StringName = &""
) -> Array[Vector3]:
	if not DotFrameCost.enabled:
		return space.collide_shape(q, max_results)
	var t := Time.get_ticks_usec()
	var r := space.collide_shape(q, max_results)
	DotFrameCost.add_query(system, COLLIDE, t)
	return r


static func move_and_collide(
	body: PhysicsBody3D, motion: Vector3, test_only: bool = false, safe_margin: float = 0.001, system: StringName = &""
) -> KinematicCollision3D:
	if not DotFrameCost.enabled:
		return body.move_and_collide(motion, test_only, safe_margin)
	var t := Time.get_ticks_usec()
	var r := body.move_and_collide(motion, test_only, safe_margin)
	DotFrameCost.add_query(system, MOVE, t)
	return r


static func body_test_motion(
	body: RID, params: PhysicsTestMotionParameters3D, result: PhysicsTestMotionResult3D = null, system: StringName = &""
) -> bool:
	if not DotFrameCost.enabled:
		return PhysicsServer3D.body_test_motion(body, params, result)
	var t := Time.get_ticks_usec()
	var r := PhysicsServer3D.body_test_motion(body, params, result)
	DotFrameCost.add_query(system, TEST, t)
	return r
