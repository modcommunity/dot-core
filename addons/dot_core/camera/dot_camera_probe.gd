class_name DotCameraProbe
extends RefCounted

## Keeps a camera out of geometry: a sphere swept from a pivot (the head it looks over, the
## vehicle it chases, the place somebody died) toward where the camera wants to be, and the
## camera put no further out than the sphere got.
##
## [codeblock]
## var probe := DotCameraProbe.new()
## probe.world = get_world_3d()
## probe.collision_mask = layout.layer_mask(&"world")
## probe.add_excluded_object(player.get_rid())
##
## # once a frame, after the pivot has moved
## camera.global_position = probe.resolve(head, wanted, delta)
## [/codeblock]
##
## [b]Why not SpringArm3D.[/b] The family used it in every third-person view, and the play
## test still had cameras inside rock, walls and arches. A spring arm casts a ray unless
## it is handed a shape, so a ray that slips through a gap between two boxes (an arch's
## pillar and its beam) leaves a camera whose near plane is inside both; it jumps to the
## hit on the frame the hit appears and back out on the frame it goes; and it excludes
## nothing, so every arm hung off a player collapsed into that player until each game
## learned to exclude it. This sweeps a sphere, eases, and takes the exclusions as data.
##
## [b]Pulling in is smooth without ever being late.[/b] A sweep along the line as it is,
## which is a hard limit applied on every frame, and sweeps along the line as it will be
## over the next [member look_ahead] seconds if the pivot and the camera keep moving the way
## they moved since the last frame. The camera eases toward the nearer of the two, so a
## pillar the view is swinging toward has already brought it in by the time the hard limit
## would bite, and a camera standing still rests exactly at the hard limit (the two lines
## are the same). Only a wall that appears faster than the look-ahead (a door slamming
## behind the head, a cut) makes the hard limit visible, and then a cut is right: the
## alternative is a frame of the inside of a door. Going back out is slower
## ([member ease_out_time]), because a camera that springs back the moment a pillar is
## passed swings in and out along a colonnade.
##
## [b]Presentation only.[/b] It reads the physics space and never writes it, keeps no
## simulation state, and its clock is the caller's delta — or, through [method clip_view],
## its own, for callers that have none (a spectator transform computed on demand).

## The space the sweep runs in. A probe without one returns what it was asked for.
var world: World3D = null

## Layers the camera stops against: the level, and usually not other characters (those
## are faded instead; see [DotCameraFade]).
var collision_mask: int = 1

## The camera's own size. Bigger than the near plane's half-diagonal (about 0.05 m at the
## stock near distance), or the far side of a wall shows through the near plane.
var radius: float = 0.2

## How far ahead, in seconds, the second sweep looks along the way the line is moving.
var look_ahead: float = 0.2

## How many moments over [member look_ahead] are swept, each along two predicted lines (a
## turn and a slide). Each line is one shape cast and one ray.
const LOOK_AHEAD_SAMPLES := 6

## Seconds to close about two-thirds of the way in toward a nearer limit.
var pull_in_time: float = 0.1

## Seconds to close about two-thirds of the way back out once the limit is gone.
var ease_out_time: float = 0.3

## A pivot that moved further than this between two calls is a cut (a respawn, a new
## spectator target), and the camera starts at its answer rather than easing from the
## old place across the map.
var cut_distance: float = 4.0

## How far in from the hit the camera stops, on top of [member radius]. A sweep is
## imprecise in proportion to its length; this is what keeps "touching" from being "in".
var skin: float = 0.03

var _excluded: Array[RID] = []
var _distance: float = -1.0
var _last_pivot: Vector3 = Vector3.ZERO
var _last_wanted_point: Vector3 = Vector3.ZERO
var _last_usec: int = 0
var _last_hard: float = 0.0
var _snapped: float = 0.0
var _last_wanted: float = 0.0


func _init(p_world: World3D = null, p_mask: int = 1) -> void:
	world = p_world
	collision_mask = p_mask


## Never stop against this body: the player the camera hangs off, the vehicle it chases.
func add_excluded_object(rid: RID) -> void:
	if rid.is_valid() and not _excluded.has(rid):
		_excluded.append(rid)


func remove_excluded_object(rid: RID) -> void:
	_excluded.erase(rid)


func clear_excluded_objects() -> void:
	_excluded.clear()


func excluded() -> Array[RID]:
	return _excluded


## How far the hard limit cut the last answer short of the eased one: non-zero only on a
## frame the camera snapped in (an obstacle faster than the look-ahead).
func last_snap() -> float:
	return _snapped


## Forget the eased distance: the next answer starts where the sweep says.
func reset() -> void:
	_distance = -1.0
	_last_usec = 0


## Where the camera may be, eased. [param pivot] must itself be clear (a head, a vehicle's
## roof); [param wanted] is where the camera would be with nothing in the way.
func resolve(pivot: Vector3, wanted: Vector3, delta: float) -> Vector3:
	var offset := wanted - pivot
	var length := offset.length()

	if length < 0.0001:
		_distance = 0.0
		_last_pivot = pivot
		_last_wanted_point = wanted
		return wanted

	var space := _space()

	if space == null:
		_last_pivot = pivot
		_last_wanted_point = wanted
		return wanted

	var direction := offset / length
	var mask := collision_mask
	var hard := clear_length(space, pivot, wanted, radius + skin, mask, _excluded)
	var cut := _distance < 0.0 or pivot.distance_to(_last_pivot) > cut_distance
	var target := hard
	# The slowest steady pull-in, in metres a second, that is inside every predicted limit
	# by the moment it is predicted for.
	var pace := 0.0

	if not cut and delta > 0.0 and look_ahead > 0.0:
		var ahead := _look_ahead_limit(space, pivot, wanted, direction, length, delta, hard)
		target = ahead.x
		pace = ahead.y

	if cut:
		_distance = target
	else:
		var time := pull_in_time if target < _distance else ease_out_time
		var eased := lerpf(_distance, target, 1.0 - exp(-maxf(delta, 0.0) / maxf(time, 0.001)))
		# Never late: every predicted limit is reached by the moment it was predicted for, at
		# an even pace, when the ease alone would still be short of it. The ease alone aims
		# at the nearest limit and gets there when it gets there; a pillar that arrives in a
		# tenth of a second needs the camera in by then, not most of the way.
		if pace > 0.0:
			eased = minf(eased, _distance - pace * delta)
		_distance = eased

	var eased := _distance
	_distance = clampf(_distance, 0.0, minf(hard, length))
	# How far the hard limit cut the eased answer short: a snap the look-ahead was too slow
	# for. Zero on every frame of ordinary motion; describe() reports it.
	_snapped = maxf(eased - _distance, 0.0) if not cut and eased <= length else 0.0
	_last_pivot = pivot
	_last_wanted_point = wanted
	_last_hard = hard
	_last_wanted = length

	return pivot + direction * _distance


## The nearest limit the line will hit over the look-ahead (x) and the slowest steady
## pull-in pace, in metres a second, that is inside every predicted limit in time (y).
func _look_ahead_limit(space: PhysicsDirectSpaceState3D, pivot: Vector3, wanted: Vector3, direction: Vector3, length: float, delta: float, hard: float) -> Vector2:
	var offset := wanted - pivot
	var mask := collision_mask
	var target := hard
	var pace := 0.0
	# Sampled at several points over the look-ahead: one sample at the end steps over a pillar
	# the line is about to cross. Each answer is a fraction of THAT line; the same fraction
	# of this one is where the camera should head now.
	var pivot_step := (pivot - _last_pivot) / delta
	# A camera orbiting a head rotates: a straight-line extrapolation cuts the arc's corner,
	# so turn the offset at its turn rate and stretch it at its stretch rate.
	var offset_last := _last_wanted_point - _last_pivot
	var axis := offset_last.cross(offset)
	var turn_rate := offset_last.angle_to(offset) / delta if axis.length_squared() > 1e-10 else 0.0
	axis = axis.normalized() if turn_rate != 0.0 else Vector3.UP
	var stretch_rate := (length - offset_last.length()) / delta

	for i in range(1, LOOK_AHEAD_SAMPLES + 1):
		var seconds := look_ahead * float(i) / float(LOOK_AHEAD_SAMPLES)
		var pivot_ahead := pivot + pivot_step * seconds
		if pivot_ahead.distance_to(pivot) > cut_distance:
			break
		var reach := maxf(length + stretch_rate * seconds, 0.0)
		# Orbit and strafe readings of the motion; each catches what the other misses.
		for wanted_ahead in [
			pivot_ahead + direction.rotated(axis, turn_rate * seconds) * reach,
			wanted + (wanted - _last_wanted_point) / delta * seconds,
		]:
			var soon_length := pivot_ahead.distance_to(wanted_ahead)
			if soon_length < 0.0001:
				continue
			var soon := clear_length(space, pivot_ahead, wanted_ahead, radius + skin, mask, _excluded)
			var limit := soon / soon_length * length
			target = minf(target, limit)
			if _distance > limit:
				pace = maxf(pace, (_distance - limit) / seconds)
	return Vector2(target, pace)


## [method resolve] for a whole transform: the basis is kept, the origin pulled in.
## Timed by its own clock, for a caller with no delta (a spectator manager asked for a
## transform). The first call, and any call after a second's silence, does not ease.
func clip_view(pivot: Vector3, wanted: Transform3D) -> Transform3D:
	var now := Time.get_ticks_usec()
	var delta := 0.0

	if _last_usec == 0 or now - _last_usec > 1_000_000:
		_distance = -1.0
	else:
		delta = float(now - _last_usec) / 1_000_000.0

	_last_usec = now
	return Transform3D(wanted.basis, resolve(pivot, wanted.origin, delta))


## How far along [param from] → [param to] a sphere of [param p_radius] travels before it
## touches something, in metres. [param to]'s whole length when nothing is in the way.
##
## Two queries, because each misses what the other sees. `cast_motion` ignores any shape
## the sphere already overlaps at [param from] — a wall the back of the head is against —
## so a ray down the same line is asked too, and the nearer of the two wins.
static func clear_length(
	space: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	p_radius: float,
	mask: int,
	exclude: Array[RID] = []
) -> float:
	var offset := to - from
	var length := offset.length()

	if length < 0.0001 or space == null:
		return length

	var sphere := SphereShape3D.new()
	sphere.radius = maxf(p_radius, 0.01)

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, from)
	params.motion = offset
	params.collision_mask = mask
	params.exclude = exclude
	params.collide_with_areas = false

	var cast := space.cast_motion(params)
	var safe := length

	if cast.size() >= 1:
		safe = clampf(float(cast[0]), 0.0, 1.0) * length

	var ray := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	ray.collide_with_areas = false
	var hit := space.intersect_ray(ray)

	if not hit.is_empty():
		var along := from.distance_to(hit["position"] as Vector3) - p_radius
		safe = minf(safe, maxf(along, 0.0))

	return safe


## Whether a sphere of [param p_radius] at [param point] overlaps anything on [param mask].
## What a check asks of every frame of a scripted path: "never inside" is this, false.
static func is_inside(
	space: PhysicsDirectSpaceState3D,
	point: Vector3,
	p_radius: float,
	mask: int,
	exclude: Array[RID] = []
) -> bool:
	if space == null:
		return false

	var sphere := SphereShape3D.new()
	sphere.radius = maxf(p_radius, 0.01)

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, point)
	params.collision_mask = mask
	params.exclude = exclude
	params.collide_with_areas = false

	return not space.intersect_shape(params, 1).is_empty()


func _space() -> PhysicsDirectSpaceState3D:
	if world == null:
		return null
	return world.direct_space_state


func describe() -> Dictionary:
	return {
		"distance": _distance,
		"hard_limit": _last_hard,
		"snapped": _snapped,
		"wanted": _last_wanted,
		"radius": radius,
		"mask": collision_mask,
		"excluded": _excluded.size(),
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"camera probe: %.2f of %.2f m (limit %.2f), radius %.2f, %d excluded" % [
			_distance, _last_wanted, _last_hard, radius, _excluded.size(),
		]
	])
