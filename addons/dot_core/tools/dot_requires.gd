extends SceneTree

## Writes, or checks, the requirements file a pack carries (see [DotAddonApi]): no args derives from the project's files, `--out F` writes, `--check F` audits.
## A `requires.floor.json` lowers the addons it names ([method DotAddonApi.apply_floors]); an unsound floor fails; a committed file is whole and unfloored.
## Exit 0 ok, 1 incomplete/overstated/unsound, 2 usage or I/O. Import first (an empty class list is refused). Document on stdout, messages on stderr.


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

	var optional := DotAddonApi.derive_optional()
	for addon in optional.keys():
		printerr("dot_requires: %s is optional (reached only behind a presence check), not required" % addon)

	var floor_path := "res://" + DotAddonApi.FLOOR_FILE
	var has_floors := FileAccess.file_exists(floor_path)

	if check_path != "":
		if has_floors:
			printerr("dot_requires: %s is committed, so %s is not applied to it" % [check_path, DotAddonApi.FLOOR_FILE])
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

	if has_floors:
		var floors_read := DotAddonApi.parse(FileAccess.get_file_as_string(floor_path), DotAddonApi.FLOOR_FILE)
		if not floors_read.ok:
			printerr("dot_requires: %s" % str(floors_read.error))
			quit(1)
			return
		var floors := floors_read.value as Dictionary
		var unsound := DotAddonApi.floor_audit(floors, derived, DotAddonApi.guarded())
		for p in unsound:
			printerr("dot_requires: %s: %s" % [DotAddonApi.FLOOR_FILE, p])
		if not unsound.is_empty():
			quit(1)
			return
		var names: Array = floors.keys()
		names.sort()
		for addon in names:
			if int(floors[addon]) < int(derived[addon]):
				printerr("dot_requires: %s built against level %d, asks for %d (guarded, %s)"
					% [addon, int(derived[addon]), int(floors[addon]), DotAddonApi.FLOOR_FILE])
		derived = DotAddonApi.apply_floors(derived, floors)

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
