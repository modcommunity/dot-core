class_name DotClipMetrics
extends RefCounted

## Numeric checks on a recorded clip, fed one sample a frame by a capture tool: foot slide,
## floor contact, framing and bone pops. Thresholds are a dictionary (a game's JSON file);
## a missing key takes the default below, and a check with no samples reports as skipped.

const DEFAULTS := {
	"plant_height_m": 0.06, "slide_mps": 0.25, "sink_m": 0.05, "float_m": 0.10, "hover_share": 0.25,
	"frame_margin": 0.02, "pop_deg": 90.0, "pop_window_s": 1.0 / 15.0, "settle_mps": 0.5, "slide_window_s": 0.2, "clip_frames_max": 0,
}

var _frames: Array[Dictionary] = []


## One frame: `t` seconds; `feet` world positions; `ground_y` under the body and whether it is
## grounded; `points` the subject's screen points (0..1) with `visible` if all are in view;
## `blocked` if something stood between the camera and the subject; `rotations` per bone.
func add(sample: Dictionary) -> void:
	_frames.append(sample)


## The limits for [param clip] from a thresholds file: its "defaults" merged with "clips"[clip].
static func limits_for(path: String, clip: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return {}
	var limits: Dictionary = (parsed as Dictionary).get("defaults", {}).duplicate()
	limits.merge((parsed as Dictionary).get("clips", {}).get(clip, {}), true)
	return limits


## Writes [param text] and [param extra] lines to [param path], making its folder.
static func write_report(path: String, text: String, extra: Array[String] = []) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text + "\n" + "\n".join(extra) + "\n")


var _feet_bones: Array[int] = []
## Per foot, the leg bone that deforms it and the foot's rest position in that bone's frame, or null.
var _feet_legs: Array = []
var _sole := NAN


## A foot bone parented straight under the skeleton root is an IK control the mesh does not follow:
## returns [leg bone, foot rest position in its frame] for the nearest lower-leg bone, else null.
static func _leg_anchor(skeleton: Skeleton3D, foot: int) -> Variant:
	var parent := skeleton.get_bone_parent(foot)
	if parent >= 0 and skeleton.get_bone_parent(parent) >= 0:
		return null
	var rest := skeleton.get_bone_global_rest(foot).origin
	var best := -1
	var gap := INF
	for i in skeleton.get_bone_count():
		var bone := skeleton.get_bone_name(i).to_lower()
		if not (bone.contains("lowerleg") or bone.contains("calf") or bone.contains("shin")):
			continue
		var d := Vector2(skeleton.get_bone_global_rest(i).origin.x - rest.x, skeleton.get_bone_global_rest(i).origin.z - rest.z).length()
		if d < gap:
			gap = d
			best = i
	if best < 0:
		return null
	return [best, skeleton.get_bone_global_rest(best).affine_inverse() * rest]


## A sample (without `points`, `blocked`) from [param skeleton]'s pose at [param t]: foot bones
## found by name, soles taken from the first frame so a foot's height is above the ground.
func pose_sample(t: float, skeleton: Skeleton3D, root: Vector3, grounded: bool) -> Dictionary:
	var sample := {"t": t, "root": root, "ground_y": root.y, "grounded": grounded}
	if skeleton == null:
		return sample
	if _feet_bones.is_empty():
		for i in skeleton.get_bone_count():
			var bone := skeleton.get_bone_name(i).to_lower()
			if bone.contains("foot") and not bone.contains("toe"):
				_feet_bones.append(i)
		for i in _feet_bones:
			_feet_legs.append(_leg_anchor(skeleton, i))
	var ankles: Array = []
	for n in _feet_bones.size():
		var anchor: Variant = _feet_legs[n]
		var at := skeleton.get_bone_global_pose(_feet_bones[n])
		if anchor != null:
			var leg: int = anchor[0]
			at = Transform3D(Basis(), skeleton.get_bone_global_pose(leg) * (anchor[1] as Vector3))
		ankles.append(skeleton.global_transform * at.origin)
	if not ankles.is_empty():
		if is_nan(_sole):
			_sole = ankles.map(func(a: Vector3) -> float: return a.y - root.y).min()
		sample["feet"] = ankles.map(func(a: Vector3) -> Vector3: return a - Vector3(0.0, _sole, 0.0))
	var rotations: Array = []
	for i in skeleton.get_bone_count():
		rotations.append(skeleton.get_bone_pose_rotation(i))
	sample["rotations"] = rotations
	return sample


## Returns rows {check, pass, value, limit, note}.
func evaluate(limits: Dictionary) -> Array[Dictionary]:
	var lim := DEFAULTS.duplicate()
	lim.merge(limits, true)
	return [_slide(lim), _floor(lim), _framing(lim), _pop(lim)]


## The rows as a text table, "PASS"/"FAIL"/"SKIP" first.
static func table(clip: String, rows: Array[Dictionary]) -> String:
	var out := PackedStringArray(["clip %s" % clip])
	for row in rows:
		var verdict := "SKIP" if row.get("skip", false) else ("PASS" if row["pass"] else "FAIL")
		out.append("%s  %-12s value %-10s limit %-8s %s" % [verdict, row["check"], row["value"], row["limit"], row.get("note", "")])
	return "\n".join(out) + "\n"


func _row(check: String, passed: bool, value: float, limit: float, note := "") -> Dictionary:
	return {"check": check, "pass": passed, "value": "%.3f" % value, "limit": "%.3f" % limit, "note": note}


func _skip(check: String) -> Dictionary:
	return {"check": check, "pass": true, "skip": true, "value": "-", "limit": "-", "note": "no samples"}


## The frame index from which the body is up to speed: root speed first reaches 90% of its peak,
## so the instant start of a clip is not judged as a foot dragging. 0 when the root never moves.
func _cruise_from() -> int:
	var peak := 0.0
	var speeds: Array[float] = [0.0]
	for i in range(1, _frames.size()):
		var a: Vector3 = _frames[i - 1].get("root", Vector3.ZERO)
		var b: Vector3 = _frames[i].get("root", Vector3.ZERO)
		var dt := float(_frames[i]["t"]) - float(_frames[i - 1]["t"])
		var speed := Vector2(b.x - a.x, b.z - a.z).length() / dt if dt > 0.0 else 0.0
		speeds.append(speed)
		peak = maxf(peak, speed)
	if peak < 0.5:
		return 0
	for i in speeds.size():
		if speeds[i] >= peak * 0.9:
			return i
	return 0


func _slide(lim: Dictionary) -> Dictionary:
	# A foot planted (low, and not landing or lifting) over a stretch where the body is up to speed
	# should stay put in the world: its world speed from the frame it settled is the skate.
	var worst := 0.0
	var worst_rel := 0.0
	var windows := 0
	var start: Dictionary = {}
	var from := _cruise_from()
	for n in range(maxi(from, 1), _frames.size()):
		var frame := _frames[n]
		var feet: Array = frame.get("feet", [])
		var before: Array = _frames[n - 1].get("feet", [])
		if feet.is_empty() or before.size() != feet.size() or not frame.get("grounded", false):
			start.clear()
			continue
		var t := float(frame["t"])
		var step := t - float(_frames[n - 1]["t"])
		var root: Vector3 = frame.get("root", Vector3.ZERO)
		for i in feet.size():
			var foot: Vector3 = feet[i]
			var rising := absf(foot.y - (before[i] as Vector3).y) / step if step > 0.0 else INF
			if foot.y - float(frame["ground_y"]) > float(lim["plant_height_m"]) or rising > float(lim["settle_mps"]):
				start.erase(i)
				continue
			if not start.has(i):
				start[i] = [foot, root, t]
				continue
			var dt: float = t - float(start[i][2])
			if dt < float(lim["slide_window_s"]) - 0.001:
				continue
			windows += 1
			var moved := Vector2(foot.x - start[i][0].x, foot.z - start[i][0].z)
			worst = maxf(worst, moved.length() / dt)
			worst_rel = maxf(worst_rel, (moved - Vector2(root.x - start[i][1].x, root.z - start[i][1].z)).length() / dt)
	if windows == 0:
		return _skip("foot_slide")
	return _row("foot_slide", worst <= float(lim["slide_mps"]), worst, float(lim["slide_mps"]),
		"m/s world speed of a planted foot >=%.2f s from when it settled, once up to speed (frame %d on, %d stretches); relative to root %.2f m/s" % [float(lim["slide_window_s"]), from, windows, worst_rel])


func _floor(lim: Dictionary) -> Dictionary:
	# Sinking is the lowest foot under the ground; hovering is the share of time both feet are
	# off the floor by more than float_m, which a run's flight phase is not (a short, regular one).
	var low := INF
	var high := -INF
	var counted := 0
	var airborne := 0
	for n in range(_cruise_from(), _frames.size()):
		var frame := _frames[n]
		var feet: Array = frame.get("feet", [])
		if feet.is_empty() or not frame.get("grounded", false):
			continue
		var lowest := INF
		for foot: Vector3 in feet:
			lowest = minf(lowest, foot.y)
		var gap := lowest - float(frame["ground_y"])
		low = minf(low, gap)
		high = maxf(high, gap)
		counted += 1
		if gap > float(lim["float_m"]):
			airborne += 1
	if counted == 0:
		return _skip("floor_contact")
	var share := float(airborne) / float(counted)
	var ok := low >= -float(lim["sink_m"]) and share <= float(lim["hover_share"])
	return _row("floor_contact", ok, share, float(lim["hover_share"]),
		"share of grounded frames with both feet >%.2f m up; lowest foot %.3f..%.3f m" % [float(lim["float_m"]), low, high])


func _framing(lim: Dictionary) -> Dictionary:
	var out_of_frame := 0
	var blocked := 0
	var seen := 0
	var margin := float(lim["frame_margin"])
	for frame in _frames:
		if not frame.has("points"):
			continue
		seen += 1
		for p: Vector2 in frame["points"]:
			if p.x < margin or p.x > 1.0 - margin or p.y < margin or p.y > 1.0 - margin:
				out_of_frame += 1
				break
		if frame.get("blocked", false):
			blocked += 1
	if seen == 0:
		return _skip("framing")
	var bad := out_of_frame + blocked
	return _row("framing", bad <= int(lim["clip_frames_max"]), float(bad), float(lim["clip_frames_max"]), "%d of %d frames out of view, %d blocked" % [out_of_frame, seen, blocked])


func _pop(lim: Dictionary) -> Dictionary:
	# Each frame against the last one at least pop_window_s before it, so a faster capture judges
	# the same span as a 15 fps one (at every phase) instead of a quarter of it.
	var worst := 0.0
	var where := 0.0
	var seen := false
	var j := 0
	for i in range(1, _frames.size()):
		while j + 1 < i and float(_frames[i]["t"]) - float(_frames[j + 1]["t"]) >= float(lim["pop_window_s"]) * 0.9:
			j += 1
		var before: Array = _frames[j].get("rotations", [])
		var now: Array = _frames[i].get("rotations", [])
		if before.size() != now.size() or now.is_empty():
			continue
		seen = true
		for b in now.size():
			var angle := rad_to_deg((before[b] as Quaternion).angle_to(now[b]))
			if angle > worst:
				worst = angle
				where = float(_frames[i]["t"])
	if not seen:
		return _skip("bone_pop")
	return _row("bone_pop", worst <= float(lim["pop_deg"]), worst, float(lim["pop_deg"]), "deg over %.3f s, at %.2f s" % [float(lim["pop_window_s"]), where])
