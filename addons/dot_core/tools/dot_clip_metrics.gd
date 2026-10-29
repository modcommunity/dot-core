class_name DotClipMetrics
extends RefCounted

## Numeric checks on a recorded clip, fed one sample a frame by a capture tool: foot slide,
## floor contact, framing and bone pops. Thresholds are a dictionary (a game's JSON file);
## a missing key takes the default below, and a check with no samples reports as skipped.

const DEFAULTS := {
	"plant_height_m": 0.06, "slide_mps": 0.25, "sink_m": 0.05, "float_m": 0.10,
	"frame_margin": 0.02, "pop_deg": 90.0, "clip_frames_max": 0,
}

var _frames: Array[Dictionary] = []


## One frame: `t` seconds; `feet` world positions; `ground_y` under the body and whether it is
## grounded; `points` the subject's screen points (0..1) with `visible` if all are in view;
## `blocked` if something stood between the camera and the subject; `rotations` per bone.
func add(sample: Dictionary) -> void:
	_frames.append(sample)


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


func _slide(lim: Dictionary) -> Dictionary:
	# A planted foot (near the floor in both frames) should not travel across it.
	var worst := 0.0
	var seen := false
	var run_start: Array[Vector3] = []
	var run_t: Array[float] = []
	for frame in _frames:
		var feet: Array = frame.get("feet", [])
		if feet.is_empty() or not frame.get("grounded", false):
			run_start.clear()
			continue
		seen = true
		if run_start.size() != feet.size():
			run_start.assign(feet)
			run_t.assign(feet.map(func(_f: Vector3) -> float: return float(frame["t"])))
			continue
		for i in feet.size():
			var foot: Vector3 = feet[i]
			if foot.y - float(frame["ground_y"]) > float(lim["plant_height_m"]):
				run_start[i] = foot
				run_t[i] = float(frame["t"])
				continue
			var dt: float = float(frame["t"]) - run_t[i]
			var flat := Vector2(foot.x - run_start[i].x, foot.z - run_start[i].z).length()
			if dt >= 0.2:
				worst = maxf(worst, flat / dt)
	if not seen:
		return _skip("foot_slide")
	return _row("foot_slide", worst <= float(lim["slide_mps"]), worst, float(lim["slide_mps"]), "m/s, planted foot over >=0.2 s")


func _floor(lim: Dictionary) -> Dictionary:
	var low := INF
	var high := -INF
	for frame in _frames:
		var feet: Array = frame.get("feet", [])
		if feet.is_empty() or not frame.get("grounded", false):
			continue
		var lowest := INF
		for foot: Vector3 in feet:
			lowest = minf(lowest, foot.y)
		var gap := lowest - float(frame["ground_y"])
		low = minf(low, gap)
		high = maxf(high, gap)
	if low == INF:
		return _skip("floor_contact")
	var ok := low >= -float(lim["sink_m"]) and high <= float(lim["float_m"])
	return _row("floor_contact", ok, high if absf(high) > absf(low) else low, float(lim["float_m"]), "lowest foot above floor: %.3f..%.3f m" % [low, high])


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
	var worst := 0.0
	var where := 0.0
	var seen := false
	for i in range(1, _frames.size()):
		var before: Array = _frames[i - 1].get("rotations", [])
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
	return _row("bone_pop", worst <= float(lim["pop_deg"]), worst, float(lim["pop_deg"]), "deg between frames, at %.2f s" % where)
