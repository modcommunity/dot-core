extends Node

## Exercises DotPlatform.has_touch(): the override beats the build, and a headless desktop has no touch.

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("dot-core platform self-test")
	var build := DotPlatform.is_mobile() or (not DotPlatform.is_headless() and DisplayServer.is_touchscreen_available())
	DotPlatform.touch_override = -1
	_check("no override asks the build", DotPlatform.has_touch() == build)
	DotPlatform.touch_override = 1
	_check("override on", DotPlatform.has_touch())
	DotPlatform.touch_override = 0
	_check("override off", not DotPlatform.has_touch())
	DotPlatform.touch_override = -1
	_check("override cleared returns to the build", DotPlatform.has_touch() == build)
	if DotPlatform.is_headless() and not DotPlatform.is_mobile():
		_check("headless desktop reports no touch", not DotPlatform.has_touch())
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 or _passed < 5 else 0)


func _check(what: String, ok: bool) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", what)
