class_name DotScenario
extends RefCounted

## A scripted play session as data: a clip is a list of steps, each applying from its time
## `t` (seconds) until the next, so another game adds a clip with JSON and no code.
##
## A step may set `move` [x, y], `yaw`, `pitch`, `turn` (degrees a second added to yaw),
## `buttons` (names the game's driver maps) and fire one-shot `event` names at its time.
## Fields persist until a later step sets them again.

var name := ""
var duration := 10.0
var steps: Array = []
var fields: Dictionary = {}


## Reads a scenario file's clips: {name: DotScenario}. Empty on a bad file.
static func load_file(path: String) -> Dictionary:
	var out := {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return out
	var defaults: Dictionary = parsed.get("defaults", {})
	for entry: Dictionary in parsed.get("clips", []):
		var clip := DotScenario.new()
		clip.name = str(entry.get("name", ""))
		clip.duration = float(entry.get("duration", 10.0))
		clip.fields = defaults.duplicate()
		clip.fields.merge(entry.get("fields", {}), true)
		clip.steps = entry.get("steps", []).duplicate()
		clip.steps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
		out[clip.name] = clip
	return out


## The merged fields in force at [param time]; `event` is never carried. Yaw integrates `turn`.
func state_at(time: float) -> Dictionary:
	var state := {"move": [0.0, 0.0], "yaw": 0.0, "pitch": 0.0, "turn": 0.0, "buttons": []}
	var yaw := 0.0
	var last := 0.0
	for step: Dictionary in steps:
		var at := float(step.get("t", 0.0))
		if at > time:
			break
		yaw += float(state["turn"]) * (at - last)
		last = at
		for key: String in step:
			if key != "t" and key != "event":
				state[key] = step[key]
		if step.has("yaw"):
			yaw = float(step["yaw"])
	state["yaw"] = yaw + float(state["turn"]) * (time - last)
	return state


## One-shot events with from_time < t <= to_time, in order.
func events_between(from_time: float, to_time: float) -> Array:
	var out := []
	for step: Dictionary in steps:
		var at := float(step.get("t", 0.0))
		if step.has("event") and at > from_time and at <= to_time:
			out.append(step)
	return out
