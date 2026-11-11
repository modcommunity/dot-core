class_name DotShotSeq
extends RefCounted
## Frame sequence after a screenshot, so a reviewer can see motion: DOT_SHOT_FRAMES frames over DOT_SHOT_SECS seconds into "<still>.seq/NNN.png". Off unless DOT_SHOT_FRAMES is set.

var _frames := 0
var _interval_msec := 0
var _dir := ""
var _taken := 0
var _next_msec := 0


## Reads the environment; true when a sequence was asked for.
func enabled() -> bool:
	_frames = clampi(OS.get_environment("DOT_SHOT_FRAMES").to_int(), 0, 48)
	var secs := clampf(OS.get_environment("DOT_SHOT_SECS").to_float() if OS.get_environment("DOT_SHOT_SECS") != "" else 2.0, 0.2, 6.0)
	_interval_msec = int(secs * 1000.0 / maxf(_frames, 1))
	return _frames > 0


## Starts a sequence beside the still at `still_path` (the still itself is frame 0).
func begin(still_path: String) -> void:
	_dir = still_path.get_basename() + ".seq"
	DirAccess.make_dir_recursive_absolute(_dir)
	_taken = 0
	_next_msec = Time.get_ticks_msec()


## Call once per frame; saves a frame when one is due. True while frames remain.
func step(viewport: Viewport) -> bool:
	if _taken >= _frames:
		return false
	if Time.get_ticks_msec() < _next_msec:
		return true
	var img := viewport.get_texture().get_image()
	if img != null:  # headless renderers give no image; still advance so callers terminate
		img.save_png("%s/%03d.png" % [_dir, _taken])
	_taken += 1
	_next_msec += _interval_msec
	return _taken < _frames


## For await-style tools: records the sequence beside `still_path` and returns when done; does nothing unless enabled.
func record(tree: SceneTree, still_path: String) -> void:
	if not enabled():
		return
	begin(still_path)
	while step(tree.root):
		await tree.process_frame
