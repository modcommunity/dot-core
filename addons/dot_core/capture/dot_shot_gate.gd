class_name DotShotGate
extends RefCounted
## For screenshot tools: waits until a game's load cover has lifted, so a shot shows the HUD and not the cover. A fixed number of seconds is wrong on a cold GPU box (the cover can outlast it) and wasteful on a warm one.


## Awaits until `platform.is_shown()` is true (DotGameClient: the load gate has lifted), polling every `poll_sec`, giving up after `timeout_sec` so a stuck cover cannot hang a shot. When it had to wait it then lets the cover's fade finish (`settle_sec`). A null `platform`, or one without `is_shown`, returns at once. Returns true when the cover is lifted, false on timeout.
static func wait_lifted(tree: SceneTree, platform: Object, timeout_sec: float = 15.0, poll_sec: float = 0.25, settle_sec: float = 1.0) -> bool:
	if not _has_shown(platform):
		return true
	var until := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	var waited := false
	while not bool(platform.call(&"is_shown")):
		if Time.get_ticks_msec() >= until:
			return false
		waited = true
		await tree.create_timer(poll_sec).timeout
		if not _has_shown(platform):
			return true
	if waited and settle_sec > 0.0:
		await tree.create_timer(settle_sec).timeout
	return true


static func _has_shown(platform: Object) -> bool:
	return platform != null and is_instance_valid(platform) and platform.has_method(&"is_shown")
