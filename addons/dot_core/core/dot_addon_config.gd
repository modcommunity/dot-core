class_name DotAddonConfig
extends RefCounted

## Where an addon's or pack's tuning lives: every `*.yml` in `cfg/addons/<addon_name>/`.
##
## [b]The convention.[/b] One directory per addon, any number of files in it. All of them are
## read, sorted by file name, and a later file's keys override an earlier one's (maps merge
## key by key; a list or a scalar is replaced whole). Sorting is the whole ordering contract:
## `10-base.yml` then `20-event.yml` is how an operator layers a seasonal change without
## editing the shipped file. A directory that is absent is not an error, because an addon
## must run with nothing configured.
##
## [b]Layers[/b], weakest first, the same as every [DotConfig]: the [param defaults] the addon
## passes < the yml files < environment < command line. Environment is
## `<ADDON>_<PATH>` upper-cased with `-`, `.` and `/` as `_` (addon `dot-map`, key
## `rotation.mode`: `DOT_MAP_ROTATION_MODE`); the command line is
## `--<addon_name>.<path>=value` (`--dot-map.rotation.mode=random`). Only a key that already
## exists in the defaults or a file can be overridden, and only with its own type, because
## that is the only way to know which `_` in the variable name is a separator. A key whose
## last segment contains `password`, `secret`, `token` or `key`, or is listed in
## [param sensitive], is refused from both, as [method DotConfig.sensitive_keys] does.
##
## [b]Where `cfg/` is[/b], weakest first, each root merged over the one before: `res://cfg`
## (shipped with the game), beside the executable (`cfg/`), `user://cfg`, then a
## `--config DIR` the process was started with (its files sit directly in `DIR`, so the
## addon directory is `DIR/addons/<name>`). A server run from a directory it does not own
## thus still finds its files, and a shipped default is never edited to tune one box.
##
## [codeblock]
## var res := DotAddonConfig.load_dir("dot-map", {"rotation": {"mode": "sequential"}})
## if not res.ok: return res
## var mode: String = DotAddonConfig.get_value(res.value, "rotation.mode", "sequential")
## [/codeblock]

const CHANNEL := "addon_config"
const SUBDIR := "addons"
const EXTENSION := "yml"
const SECRET_WORDS: PackedStringArray = ["password", "secret", "token", "key"]

## addon name -> {roots, files, overrides, refused}, kept for [method describe].
static var _last: Dictionary = {}


## The directory that wins for [param addon_name]: the strongest root that has one. When none
## exists, where one would be created: under `user://cfg`, the only root a game may write.
static func dir_for(addon_name: String) -> String:
	var dirs := _candidate_dirs(addon_name)
	for i in range(dirs.size() - 1, -1, -1):
		if DirAccess.dir_exists_absolute(dirs[i]):
			return dirs[i]
	return "user://cfg".path_join(SUBDIR).path_join(addon_name)


## Reads every yml for [param addon_name] over [param defaults]. Value: the merged Dictionary
## (a fresh copy; [param defaults] is never mutated). A missing directory returns the
## defaults. A bad file fails with [constant DotError.CODE_PARSE] (or CODE_IO) naming the file.
static func load_dir(
	addon_name: String,
	defaults: Dictionary = {},
	sensitive: PackedStringArray = PackedStringArray()
) -> DotResult:
	if addon_name.strip_edges().is_empty() or addon_name.contains("/") or addon_name.contains(".."):
		return DotResult.fail(DotError.CODE_INVALID, "Bad addon name for config: '%s'" % addon_name)

	var merged: Dictionary = defaults.duplicate(true)
	var files := PackedStringArray()
	var roots := PackedStringArray()

	for dir in _candidate_dirs(addon_name):
		if not DirAccess.dir_exists_absolute(dir):
			continue
		roots.append(dir)
		var names := PackedStringArray()
		for f in DirAccess.get_files_at(dir):
			if f.get_extension().to_lower() == EXTENSION:
				names.append(f)
		names.sort()
		for f in names:
			var path := dir.path_join(f)
			var res := DotYaml.parse_file(path)
			if not res.ok:
				DotLog.error(CHANNEL, "bad config file", {"addon": addon_name, "file": path})
				return res.wrap("%s: config file %s" % [addon_name, f])
			if not (res.value is Dictionary):
				if res.value == null:
					continue  # An empty file sets nothing.
				var bad := DotResult.fail(
					DotError.CODE_PARSE, "%s must hold a mapping at the top level." % path
				)
				DotLog.error(CHANNEL, "bad config file", {"addon": addon_name, "file": path})
				return bad
			_merge(merged, res.value as Dictionary)
			files.append(path)

	var overrides := PackedStringArray()
	var refused := PackedStringArray()
	_apply_layer(addon_name, merged, sensitive, overrides, refused)

	_last[addon_name] = {"roots": roots, "files": files, "overrides": overrides, "refused": refused}
	DotLog.debug(CHANNEL, "loaded", {"addon": addon_name, "files": files.size(), "overrides": overrides.size()})
	return DotResult.success(merged)


## Reads a dotted path out of a loaded config; [param default] when absent.
static func get_value(cfg: Dictionary, path: String, default: Variant = null) -> Variant:
	return DotYaml.at(cfg, path, default)


## What [method load_dir] last did for [param addon_name] (or for each addon when empty).
static func describe(addon_name: String = "") -> String:
	return "\n".join(describe_lines(addon_name))


static func describe_lines(addon_name: String = "") -> PackedStringArray:
	var lines := PackedStringArray()
	var names: Array = [addon_name] if addon_name != "" else _last.keys()
	names.sort()
	for n in names:
		if not _last.has(n):
			lines.append("%s: not loaded (dir would be %s)" % [n, dir_for(n)])
			continue
		var s: Dictionary = _last[n]
		lines.append("%s: %d file(s), %d env/cli override(s)" % [n, (s["files"] as PackedStringArray).size(), (s["overrides"] as PackedStringArray).size()])
		for f in s["files"]:
			lines.append("  file %s" % f)
		for o in s["overrides"]:
			lines.append("  override %s" % o)
		for r in s["refused"]:
			lines.append("  refused (sensitive) %s" % r)
	return lines


# --- Internals -------------------------------------------------------------

static func _config_dir_arg() -> String:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "--config" and i + 1 < args.size():
			return args[i + 1]
		if args[i].begins_with("--config="):
			return args[i].substr(9)
	return ""


## Addon directories, weakest root first.
static func _candidate_dirs(addon_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var sub := SUBDIR.path_join(addon_name)
	out.append("res://cfg".path_join(sub))
	var exe := OS.get_executable_path().get_base_dir()
	if exe != "":
		out.append(exe.path_join("cfg").path_join(sub))
	out.append("user://cfg".path_join(sub))
	var given := _config_dir_arg()
	if given != "":
		out.append(given.path_join(sub))
	return out


## Deep merge: maps by key, everything else replaced.
static func _merge(into: Dictionary, over: Dictionary) -> void:
	for k in over:
		if into.get(k) is Dictionary and over[k] is Dictionary:
			_merge(into[k] as Dictionary, over[k] as Dictionary)
		else:
			into[k] = over[k].duplicate(true) if (over[k] is Dictionary or over[k] is Array) else over[k]


static func _leaf_paths(tree: Dictionary, prefix: String, out: PackedStringArray) -> void:
	for k in tree:
		var p := "%s%s" % [prefix, k]
		if tree[k] is Dictionary:
			_leaf_paths(tree[k] as Dictionary, p + ".", out)
		else:
			out.append(p)


static func _is_sensitive(path: String, extra: PackedStringArray) -> bool:
	var last := path.get_slice(".", path.count("."))
	if extra.has(path) or extra.has(last):
		return true
	var low := last.to_lower()
	for w in SECRET_WORDS:
		if low.contains(w):
			return true
	return false


static func _env_name(addon_name: String, path: String) -> String:
	var s := "%s_%s" % [addon_name, path]
	return s.to_upper().replace("-", "_").replace(".", "_").replace("/", "_")


static func _apply_layer(
	addon_name: String, merged: Dictionary, sensitive: PackedStringArray,
	overrides: PackedStringArray, refused: PackedStringArray
) -> void:
	var leaves := PackedStringArray()
	_leaf_paths(merged, "", leaves)
	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var cli_prefix := "--%s." % addon_name

	for path in leaves:
		var raw: Variant = null
		var from := ""
		var env_key := _env_name(addon_name, path)
		if OS.has_environment(env_key):
			raw = OS.get_environment(env_key)
			from = "env " + env_key
		# Command line is stronger, so it is read second and wins.
		for i in argv.size():
			var a: String = argv[i]
			if not a.begins_with(cli_prefix + path):
				continue
			var rest := a.substr(cli_prefix.length() + path.length())
			if rest.begins_with("="):
				raw = rest.substr(1)
				from = "cli " + a.get_slice("=", 0)
			elif rest == "" and i + 1 < argv.size():
				raw = argv[i + 1]
				from = "cli " + a
		if raw == null:
			continue
		if _is_sensitive(path, sensitive):
			refused.append("%s (%s)" % [path, from])
			DotLog.warn(CHANNEL, "secret refused from environment/argv", {"addon": addon_name, "key": path})
			continue
		var node := merged
		var parts := path.split(".")
		for j in parts.size() - 1:
			node = node[parts[j]]
		var key := parts[parts.size() - 1]
		var coerced: Variant = _coerce(str(raw), node[key])
		if coerced == null:
			DotLog.warn(CHANNEL, "override has the wrong type", {"addon": addon_name, "key": path, "from": from})
			continue
		node[key] = coerced
		overrides.append("%s <- %s" % [path, from])


## Parses [param text] as the type of [param current]; null when it will not.
static func _coerce(text: String, current: Variant) -> Variant:
	match typeof(current):
		TYPE_BOOL:
			var low := text.to_lower()
			if low in ["true", "1", "yes", "on"]:
				return true
			if low in ["false", "0", "no", "off"]:
				return false
			return null
		TYPE_INT:
			return int(text) if text.is_valid_int() else null
		TYPE_FLOAT:
			return float(text) if text.is_valid_float() else null
		TYPE_STRING, TYPE_STRING_NAME:
			return text
		TYPE_ARRAY:
			var items: Array = []
			for part in text.split(","):
				items.append(part.strip_edges())
			return items
	return null
