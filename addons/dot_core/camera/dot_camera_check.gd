class_name DotCameraCheck
extends RefCounted

## Flies a third-person, chase or death camera along a scripted path through a real level
## and counts the frames it ended inside geometry: the check every game's camera tool runs
## against its own maps.
##
## [codeblock]
## var path := DotCameraCheck.orbit_path(spawn_eye)        # one turn round a spawn
## var got := DotCameraCheck.fly(get_world_3d(), path, Vector3(0.4, 0.3, 2.6), level_mask)
## print(DotCameraCheck.summary(got))
## if not DotCameraCheck.passed(got): quit(1)
## [/codeblock]
##
## [b]Armed by construction.[/b] Every frame is asked twice: where the camera wanted to be
## (no probe), and where [DotCameraProbe] put it. [method passed] requires the first to be
## inside or behind the level on some frames, so a path that never goes near a wall cannot
## pass, and the second on none. A probe that snapped (cut a third of a metre off its eased
## answer in one frame) fails it too.

## One turn of the view round [param pivot] over [param frames] frames, the pitch swinging
## between [param pitch_low] and [param pitch_high] (radians; negative looks down, which
## lifts a camera behind the head), so the camera passes over every wall and under any
## roof near the pivot.
static func orbit_path(
	pivot: Vector3, frames: int = 180, pitch_low: float = -0.6, pitch_high: float = 0.35
) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in frames:
		var t := float(i) / float(maxi(frames - 1, 1))
		var yaw := TAU * t
		var pitch := lerpf(pitch_low, pitch_high, 0.5 - 0.5 * cos(t * TAU * 2.0))
		out.append(Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), pivot))
	return out


## A walk from [param from] to [param to] over [param frames] frames, looking along
## [param yaw] (radians) while swinging [param swing] either side of it.
static func walk_path(
	from: Vector3, to: Vector3, frames: int = 180, yaw: float = 0.0, swing: float = 0.8
) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in frames:
		var t := float(i) / float(maxi(frames - 1, 1))
		var y := yaw + sin(t * TAU * 1.5) * swing
		out.append(Transform3D(Basis.from_euler(Vector3(-0.2, y, 0.0)), from.lerp(to, t)))
	return out


## Flies a fresh [DotCameraProbe] along [param path]: each transform is a pivot and the
## view's axes, and the camera wants to be at `origin + basis * offset`. Returns the counts.
static func fly(
	world: World3D,
	path: Array[Transform3D],
	offset: Vector3,
	mask: int,
	exclude: Array[RID] = [],
	radius: float = 0.2,
	delta: float = 1.0 / 60.0
) -> Dictionary:
	var probe := DotCameraProbe.new(world, mask)
	probe.radius = radius
	for rid in exclude:
		probe.add_excluded_object(rid)

	var space := world.direct_space_state if world != null else null
	var inside := 0
	var unprotected := 0
	var snaps := 0
	var worst_snap := 0.0
	var pulled := 0
	var frames: Array[Dictionary] = []

	for t in path:
		var pivot := t.origin
		var wanted := pivot + t.basis * offset
		var got := probe.resolve(pivot, wanted, delta)

		var ray := PhysicsRayQueryParameters3D.create(pivot, wanted, mask, exclude)
		var blocked := space != null and not space.intersect_ray(ray).is_empty()

		if blocked or DotCameraProbe.is_inside(space, wanted, radius * 0.9, mask, exclude):
			unprotected += 1

		if DotCameraProbe.is_inside(space, got, radius * 0.9, mask, exclude):
			inside += 1

		if got.distance_to(wanted) > 0.05:
			pulled += 1

		worst_snap = maxf(worst_snap, probe.last_snap())
		if probe.last_snap() > 0.3:
			snaps += 1
			if OS.get_environment("CAMERA_DEBUG") != "":
				print("    snap %.2f m at frame %d: pivot %s wanted %s got %s, hard %.2f" % [probe.last_snap(), frames.size(), pivot, wanted, got, float(probe.describe()["hard_limit"])])

		frames.append({"pivot": pivot, "wanted": wanted, "got": got, "basis": t.basis})

	return {
		"frames": path.size(), "unprotected": unprotected, "inside": inside,
		"pulled": pulled, "snaps": snaps, "worst_snap": worst_snap, "poses": frames,
	}


## Whether a flight is a pass: armed (the unprotected camera was in or behind the level on
## at least [param armed_at_least] frames) and clean (inside on none, no snap).
static func passed(got: Dictionary, armed_at_least: int = 1) -> bool:
	return int(got["unprotected"]) >= armed_at_least and int(got["inside"]) == 0 and int(got["snaps"]) == 0


static func summary(got: Dictionary) -> String:
	return "%d frames: unprotected camera in or behind the level on %d (armed), probed camera inside on %d, pulled in on %d, %d snaps (largest cut %.2f m)" % [
		got["frames"], got["unprotected"], got["inside"], got["pulled"], got["snaps"], got["worst_snap"],
	]


## Adds [param more] to [param total], for a tool that flies several paths.
static func add(total: Dictionary, more: Dictionary) -> Dictionary:
	if total.is_empty():
		return more.duplicate()
	for key in ["frames", "unprotected", "inside", "pulled", "snaps"]:
		total[key] = int(total[key]) + int(more[key])
	total["worst_snap"] = maxf(float(total["worst_snap"]), float(more["worst_snap"]))
	return total
