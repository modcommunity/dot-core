class_name DotViewLens
extends RefCounted

## The maths that draws a first-person model at its own field of view under the camera's: a
## scale of X and Y plus a pull along Z that keeps its apparent size. Held weapons and tools share it.

## The lens and depth a held model is authored at.
const REFERENCE_FOV := 90.0
const REFERENCE_DEPTH := 0.55
## The furthest a model is pulled toward the eye to make up for a wider lens.
const MAX_PULL_IN := 0.1


## The vertical field of view that is [param horizontal] degrees across a 4:3 frame.
static func vertical_from_horizontal_4_3(horizontal: float) -> float:
	var half := deg_to_rad(clampf(horizontal, 20.0, 170.0) * 0.5)
	return rad_to_deg(2.0 * atan(tan(half) * 3.0 / 4.0))


## How much X and Y are scaled to draw at [param hands] degrees under a [param camera]-degree lens. 1 when either is unusable.
static func lens_scale(camera: float, hands: float) -> float:
	if hands <= 1.0 or hands >= 179.0 or camera <= 1.0 or camera >= 179.0:
		return 1.0
	return tan(deg_to_rad(camera) * 0.5) / tan(deg_to_rad(hands) * 0.5)


## Scales and positions [param model] (a child of [param camera]) to draw at [param hands] degrees.
## [param depth_comp] scales the pull-in; [param extra_z] is added after it (a kick). No camera: identity.
static func apply(model: Node3D, camera: Camera3D, hands: float, depth_comp: float = 1.0, extra_z: float = 0.0) -> void:
	var k := lens_scale(camera.fov, hands) if camera != null else 1.0
	model.scale = Vector3(k, k, 1.0)
	var size := lens_scale(REFERENCE_FOV, hands) if camera != null else 1.0
	model.position = Vector3(0.0, 0.0, -maxf((size - 1.0) * REFERENCE_DEPTH * depth_comp, -MAX_PULL_IN) + extra_z)
