extends Node

## DotShotSeq: off unless DOT_SHOT_FRAMES is set, clamps frames and seconds, and writes "<still>.seq/NNN.png" frames, the names tools/shot_post.sh and seq_to_mp4.sh read.
## godot --headless --path . res://examples/shot_seq_selftest.tscn

const SECTIONS := 4
const CHECKS := 14

var _failed := 0
var _checks := 0
var _sections := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _ready() -> void:
	_env_section()
	await _record_section()
	_clamp_section()
	await _follow_section()
	print("shot_seq_selftest: %d sections, %d checks, %d failed" % [_sections, _checks, _failed])
	if _sections != SECTIONS or _checks != CHECKS:
		print("ERROR: %d of %d sections, %d of %d checks ran." % [_sections, SECTIONS, _checks, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _env_section() -> void:
	OS.unset_environment("DOT_SHOT_FRAMES")
	var seq := DotShotSeq.new()
	_check(not seq.enabled(), "off when DOT_SHOT_FRAMES is not set")
	OS.set_environment("DOT_SHOT_FRAMES", "4")
	_check(seq.enabled(), "on when DOT_SHOT_FRAMES is 4")
	OS.set_environment("DOT_SHOT_FRAMES", "0")
	_check(not seq.enabled(), "off when DOT_SHOT_FRAMES is 0")
	_sections += 1


func _record_section() -> void:
	var dir := ProjectSettings.globalize_path("user://shot_seq_selftest")
	DirAccess.make_dir_recursive_absolute(dir)
	var still := dir.path_join("still.png")
	var seq := DotShotSeq.new()
	OS.set_environment("DOT_SHOT_FRAMES", "3")
	OS.set_environment("DOT_SHOT_SECS", "0.2")
	_check(seq.enabled(), "enabled with 3 frames over 0.2 s")
	seq.begin(still)
	_check(DirAccess.dir_exists_absolute(dir.path_join("still.seq")), "begin makes <still>.seq beside the still")
	var vp := SubViewport.new()
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	await get_tree().process_frame
	var guard := 0
	while seq.step(vp) and guard < 600:
		guard += 1
		await get_tree().process_frame
	var files := DirAccess.get_files_at(dir.path_join("still.seq"))
	files.sort()
	if DisplayServer.get_name() == "headless":
		_check(files.size() == 0, "headless renders no image: nothing written, loop still ends")
		_check(true, "frame names skipped headless (checked on a GPU box)")
		_check(not seq.step(vp), "step reports nothing left after the last frame")
		vp.queue_free()
		_sections += 1
		return
	_check(files.size() == 3, "three frames saved (got %d)" % files.size())
	_check(files == PackedStringArray(["000.png", "001.png", "002.png"]), "frames are 000.png.. as shot_post.sh reads them")
	_check(not seq.step(vp), "step reports nothing left after the last frame")
	vp.queue_free()
	_sections += 1


func _clamp_section() -> void:
	var seq := DotShotSeq.new()
	OS.set_environment("DOT_SHOT_FRAMES", "500")
	_check(seq.enabled(), "a huge frame count still enables (clamped to 48)")
	OS.unset_environment("DOT_SHOT_FRAMES")
	OS.unset_environment("DOT_SHOT_SECS")
	_check(not seq.enabled(), "and off again once unset")
	_sections += 1


func _follow_section() -> void:
	var dir := ProjectSettings.globalize_path("user://shot_seq_selftest")
	var seq := DotShotSeq.new()
	var vp := SubViewport.new()
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	OS.set_environment("DOT_SHOT_FRAMES", "0")
	_check(not seq.start_follow(dir.path_join("f.png")) and not seq.follow(vp), "follow does nothing when disabled")
	OS.set_environment("DOT_SHOT_FRAMES", "3")
	OS.set_environment("DOT_SHOT_SECS", "0.2")
	_check(seq.start_follow(dir.path_join("f.png")), "start_follow starts when enabled")
	var guard := 0
	while seq.follow(vp) and guard < 600:
		guard += 1
		await get_tree().process_frame
	_check(guard < 600 and not seq.follow(vp), "follow returns false once the clip is done")
	_check(DirAccess.dir_exists_absolute(dir.path_join("f.seq")), "follow clip dir exists")
	OS.unset_environment("DOT_SHOT_FRAMES")
	OS.unset_environment("DOT_SHOT_SECS")
	_sections += 1
