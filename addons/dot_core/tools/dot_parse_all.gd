extends SceneTree

## Compiles every script in a list inside ONE Godot process: the family's parse pass (66 scripts: 40 s per-file, 4 s here; same verdicts).
## `--script ... -- <list-file>` or PARSE_LIST; one path per line. Per script: `PARSE> <path>` on stderr, `PARSE_FAIL <path>` after a failure, then `PARSE_END`;
## stdout `PARSED <n> FAILED <m>`, exit 1 on failure. Callers must still read stderr. No class_name, so no consumer re-imports.


func _initialize() -> void:
	var path := OS.get_environment("PARSE_LIST")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		path = args[0]
	if path.is_empty() or not FileAccess.file_exists(path):
		printerr("PARSE_FAIL list not readable: ", path)
		print("PARSED 0 FAILED 1")
		quit(1)
		return

	var bad := 0
	var total := 0
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var p := line.strip_edges()
		if p.is_empty():
			continue
		if not (p.begins_with("res://") or p.begins_with("user://")):
			p = "res://" + p.trim_prefix("./")
		total += 1
		printerr("PARSE> ", p)
		# This script is the one running: it compiled or we would not be here, and
		# reload() on a script in use fails, which would call every project's own copy bad.
		if p == (get_script() as Script).resource_path:
			continue
		var s = ResourceLoader.load(p, "Script", ResourceLoader.CACHE_MODE_IGNORE)
		# Typed, so the call binds to the engine's GDScript.reload(). An untyped s.reload()
		# is looked up in the script's own methods first: a script that declares, or
		# inherits, a non-static reload() (dot-vote's sources do) errors there instead.
		var gd := s as GDScript
		if s == null or (gd != null and gd.reload() != OK):
			printerr("PARSE_FAIL ", p)
			bad += 1
	printerr("PARSE_END")
	print("PARSED ", total, " FAILED ", bad)
	quit(1 if bad > 0 else 0)
