extends SceneTree

## Writes, or checks, the requirements file a pack carries. See [DotAddonApi].
##
## [codeblock]
## # What this project's files use, at the levels this build's addons have:
## godot --headless --path <game> --script res://addons/dot_core/tools/dot_requires.gd
##
## # Written into a pack being built (dot-ci's package.sh --pack does this):
## godot --headless --path <game> --script res://addons/dot_core/tools/dot_requires.gd \
##     -- --out /tmp/pack/requires.json
##
## # A file the game committed, checked against what its files use:
## godot --headless --path <game> --script res://addons/dot_core/tools/dot_requires.gd \
##     -- --check requires.json
## [/codeblock]
##
## Exit codes: 0 ok, 1 a committed file is incomplete or overstated, 2 usage or I/O.
## The project has to have been imported first, or the global class list is empty and
## nothing is found -- which is refused rather than written, because an empty file would
## claim the game needs nothing.
##
## Output is the document on stdout and everything said to a person on stderr, so a
## caller can redirect the one without the other.


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := _arg(args, "--out")
	var check_path := _arg(args, "--check")

	if ProjectSettings.get_global_class_list().is_empty():
		printerr("dot_requires: no global classes; import the project first (godot --headless --import)")
		quit(2)
		return

	var derived := DotAddonApi.derive()

	if derived.is_empty():
		printerr("dot_requires: this project uses no addon this build has; nothing to require")

	if check_path != "":
		var abs_check := check_path if check_path.contains("://") else "res://" + check_path
		if not FileAccess.file_exists(abs_check):
			printerr("dot_requires: no such file: %s" % abs_check)
			quit(2)
			return
		var parsed := DotAddonApi.parse(FileAccess.get_file_as_string(abs_check))
		if not parsed.ok:
			printerr("dot_requires: %s" % str(parsed.error))
			quit(1)
			return
		var problems := DotAddonApi.audit(parsed.value as Dictionary, derived)
		for p in problems:
			printerr("dot_requires: %s: %s" % [check_path, p])
		if problems.is_empty():
			printerr("dot_requires: %s covers the %d addons this game uses" % [check_path, derived.size()])
		quit(1 if not problems.is_empty() else 0)
		return

	var text := DotAddonApi.encode(derived)

	if out_path != "":
		var file := FileAccess.open(out_path, FileAccess.WRITE)
		if file == null:
			printerr("dot_requires: cannot write %s (%s)" % [out_path, error_string(FileAccess.get_open_error())])
			quit(2)
			return
		file.store_string(text)
		file.close()
		printerr("dot_requires: wrote %d requirements to %s" % [derived.size(), out_path])
	else:
		print(text.strip_edges())

	quit(0)


static func _arg(args: PackedStringArray, flag: String) -> String:
	var i := args.find(flag)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return ""
