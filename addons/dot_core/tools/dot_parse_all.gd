extends SceneTree

## Compiles every script in a list inside ONE Godot process: the family's parse pass.
##
## [codeblock]
## godot --headless --path <project> --script res://addons/dot_core/tools/dot_parse_all.gd -- <list-file>
## # or the list's path in the environment: PARSE_LIST=<list-file>
## [/codeblock]
##
## The list is one path per line: relative to the project (taken as [code]res://[/code]),
## or already a [code]res://[/code] or [code]user://[/code] path.
##
## [b]Why one process.[/b] [code]--check-only --script[/code] once per file pays the engine's
## start-up and the class-cache load for every script: 66 scripts took 40 s that way and
## 4 s here. Detection is the same: a syntax error, a type mismatch, an undeclared
## identifier and a preload of a broken script all fail here exactly as they do there.
## [code]CACHE_MODE_IGNORE[/code] plus [code]reload()[/code] so a script already pulled in
## by an earlier one's preload is still compiled and judged on its own.
##
## [b]The contract the callers rely on[/b] (dot-ci's check.sh, every game.sh): the old pass
## called a script bad if the engine wrote ANYTHING to stderr for it, so a caller needs to
## attribute stderr to files. Before loading each script this prints
## [code]PARSE> <path>[/code] on stderr, the same stream as the engine's own errors, so the
## order is kept. A failed script is then named by [code]PARSE_FAIL <path>[/code]. After the
## last one comes [code]PARSE_END[/code] (anything later is shutdown noise, not a script's).
## Stdout gets [code]PARSED <n> FAILED <m>[/code]. Exit code 1 if anything failed (or the
## list is unreadable), else 0. A caller still has to read stderr: an engine message
## with no failed load (a warning promoted to an error, say) is a failure to it.
##
## No [code]class_name[/code]: it adds no global, so no consumer needs a re-import.


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
		if s == null or (s is GDScript and s.reload() != OK):
			printerr("PARSE_FAIL ", p)
			bad += 1
	printerr("PARSE_END")
	print("PARSED ", total, " FAILED ", bad)
	quit(1 if bad > 0 else 0)
