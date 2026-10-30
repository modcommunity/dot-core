class_name DotFrameSlice
extends RefCounted

## A time budget for a long synchronous build behind a loading cover: ask [method due] in the loop and [code]await pause()[/code] when it is true, so the cover keeps animating and the window is not "not responding".

## Milliseconds of work between pauses. A cover has no gameplay to protect, but under 50 ms keeps a spinner moving.
var budget_ms: int = 40

var _since: int = 0


func _init(budget: int = 40) -> void:
	budget_ms = budget
	_since = Time.get_ticks_msec()


## Whether the budget since the last pause is spent.
func due() -> bool:
	return Time.get_ticks_msec() - _since >= budget_ms


## Waits one frame and restarts the budget. A host with no tree (a test) returns at once.
func pause() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame
	_since = Time.get_ticks_msec()
