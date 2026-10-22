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
## that is the only way to know which `_` in the variable name is a separator. A key is
## refused from both when any segment of its path, split on `_`, `-` and camelCase, holds the
## word `password`, `secret`, `token` (or their plurals) or ends in the word `key` (`api_key`
## yes; `hotkey`, `keybind`, `key_repeat` no), or when it is listed in [param sensitive]. Two
## leaf paths that map to the same variable name (`a_b.c` and `a.b_c`) are ambiguous: the
## variable is applied to neither, with one WARN; the command line is unambiguous.
##
## [b]Shipping.[/b] An export drops `.yml` from the PCK unless the preset's `include_filter`
## lists it: see [method export_filter_hint].
##
## [b]Where `cfg/` is[/b], weakest first, each root merged over the one before: `res://cfg`
## (shipped with the game), beside the executable (`cfg/`), `user://cfg`, then a
## `--config DIR` the process was started with (its files sit directly in `DIR`, so the
## addon directory is `DIR/addons/<name>`; the name is the folder form, `-` as `_`, so `dot-map`
## reads `addons/dot_map`). Two more tiers in the same roots are read after, so they win: the
## game's `game/<game>/<name>/` (only when [member game] is set) and the operator's
## `server/addons/<name>/`, which is how a box overrides what a game or addon ships. A server run
## from a directory it does not own thus still finds its files, and a shipped default is never
## edited to tune one box. The old `server/<name>/` is still read through [DotCfgLegacy].
##
## [codeblock]
## var res := DotAddonConfig.load_dir("dot-map", {"rotation": {"mode": "sequential"}})
## if not res.ok: return res
## var mode: String = DotAddonConfig.get_value(res.value, "rotation.mode", "sequential")
## [/codeblock]

const CHANNEL := "addon_config"
const SUBDIR := "addons"
## The operator override layer: `cfg/server/addons/<addon_underscored>/`, mirroring `cfg/addons/`.
const SERVER_SUBDIR := "server/addons"
## The game layer between the addon's and the operator's: `cfg/game/<game>/<addon_underscored>/`.
const GAME_SUBDIR := "game"
## The player's own layer, `user://cfg/user/addons/<addon_underscored>/`, between game and operator; see [method set_user_tier].
const USER_SUBDIR := "user/addons"
## The operator's per-game layer, strongest: `cfg/server/game/<game>/<addon_underscored>/`.
const SERVER_GAME_SUBDIR := "server/game"
## The operator layer before the mirror: `cfg/server/<addon_underscored>/`, shimmed by [DotCfgLegacy].
const LEGACY_SERVER_SUBDIR := "server"
const EXTENSION := "yml"
## Whole words that make any path segment secret. `key` is separate: only as the last word.
const SECRET_WORDS: PackedStringArray = ["password", "passwords", "passwd", "secret", "secrets", "token", "tokens", "apikey"]

## The game whose `cfg/game/<game>/` tier is read; empty skips that tier. A game sets it once at start.
static var game: String = ""

## Whether the player's user tier is read. Off by default: only a solo or listen-host process turns it on
## ([method set_user_tier]); a dedicated server or a connected client keeps it off, so a file on a
## player's disk never changes what a server says.
static var user_tier_enabled := false

## A `--config`-style root to read as well when the command line names none: a host that was handed its cfg directory another way sets it.
static var config_root: String = ""

## addon name -> {roots, files, overrides, refused}, kept for [method describe].
static var _last: Dictionary = {}
## Env names already warned about as ambiguous, so a reload does not repeat the line.
static var _warned_ambiguous: Dictionary = {}


## The directory a [b]read[/b] finds first: the strongest root that has one (it may be
## read-only, such as `res://cfg` or the executable's directory). When none exists, the
## `user://cfg` path. Never write here; use [method write_dir_for].
static func dir_for(addon_name: String) -> String:
	var dirs := _candidate_dirs(addon_name)
	for i in range(dirs.size() - 1, -1, -1):
		if DirAccess.dir_exists_absolute(dirs[i]):
			return dirs[i]
	return write_dir_for(addon_name)


## The folder name for an addon: the repository name with `-` as `_` (`dot-map` is `dot_map`).
static func folder_name(addon_name: String) -> String:
	return addon_name.replace("-", "_")


## Every existing copy of one addon file, weakest first: `cfg/addons/<addon>/<file>`, then
## `cfg/game/<game>/<addon>/<file>`, then the operator's `cfg/server/addons/<addon>/<file>` and
## `cfg/server/game/<game>/<addon>/<file>`, each in every root (the old `cfg/server/<addon>/<file>` stands in for a missing new copy). For a single file such as
## `maps.yml` that a reader layers itself; [param extra_dir] is a `--config`-style root put last.
static func file_layers(addon_name: String, file: String, extra_dir: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	for tier in [SUBDIR, GAME_SUBDIR, USER_SUBDIR, SERVER_SUBDIR, SERVER_GAME_SUBDIR]:
		var dirs := _tier_dirs(addon_name, tier, extra_dir)
		var olds := _tier_dirs(addon_name, LEGACY_SERVER_SUBDIR, extra_dir) if tier == SERVER_SUBDIR else PackedStringArray()
		for i in dirs.size():
			var path := dirs[i].path_join(file)
			if i < olds.size():
				path = DotCfgLegacy.find(olds[i].path_join(file), path)
				if path != "":
					out.append(path)
			elif FileAccess.file_exists(path):
				out.append(path)
	return out


## For a list file an operator may replace (a map rotation): the layers of [method file_layers] that
## apply, weakest first. A layer whose top level lacks `merge: true` replaces every weaker one, so only
## the strongest such layer and the `merge: true` layers over it remain.
static func replace_aware_layers(addon_name: String, file: String, extra_dir: String = "") -> PackedStringArray:
	var all := file_layers(addon_name, file, extra_dir)
	var start := 0
	for i in range(all.size() - 1, -1, -1):
		var parsed := DotYaml.parse_file(all[i])
		var wants_merge: bool = parsed.ok and parsed.value is Dictionary and (parsed.value as Dictionary).get("merge") == true
		if not wants_merge:
			start = i
			break
	return all.slice(start)


## Reads one named yml for an addon that applies it to its own typed config: `cfg/addons/<folder>/`
## the game's, then the operator's `cfg/server/addons/<folder>/` (weakest first), each handed to [param apply], a
## `func(values: Dictionary, path: String) -> PackedStringArray`. A flat [param legacy_dir]/[param file_name]
## is read instead, with one WARN, while no new copy exists. Value: the strings [param apply] returned.
## Secrets are the caller's to keep file-only: this never touches the environment or command line.
static func apply_file(addon_name: String, file_name: String, legacy_dir: String, apply: Callable) -> DotResult:
	var layers := file_layers(addon_name, file_name)
	var newest := (
		layers[layers.size() - 1] if not layers.is_empty()
		else write_dir_for(addon_name).path_join(file_name)
	)
	var old_path := legacy_dir.path_join(file_name) if legacy_dir != "" else ""
	if old_path != "" and DotCfgLegacy.find(old_path, newest) == old_path:
		layers = PackedStringArray([old_path])

	var applied := PackedStringArray()
	for path in layers:
		var parsed := DotYaml.parse_file(path)
		if not parsed.ok:
			return parsed.wrap("Could not read '%s'." % path)
		if parsed.value == null:
			continue
		if not (parsed.value is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "'%s' must hold a mapping at the top level." % path)
		applied.append_array(apply.call(parsed.value as Dictionary, path))
	return DotResult.success(applied)


## Where a write belongs: `user://cfg/addons/<addon_underscored>`, the only root a game may write.
## It is not always the directory [method dir_for] reads from, and a file written here is
## overridden by a `--config DIR` that also holds the addon. Call
## [code]DotWeb.sync_filesystem()[/code] after writing.
static func write_dir_for(addon_name: String) -> String:
	return "user://cfg".path_join(SUBDIR).path_join(folder_name(addon_name))


## Turns the player's user tier on for a solo or listen-host process, off for a server or a connected client.
## Also switches [member DotProfileSet.user_tier_enabled].
static func set_user_tier(enabled: bool) -> void:
	user_tier_enabled = enabled
	DotProfileSet.user_tier_enabled = enabled


## Directory of the user tier for an addon: `user://cfg/user/addons/<addon_underscored>`.
static func user_dir_for(addon_name: String) -> String:
	return "user://cfg".path_join(USER_SUBDIR).path_join(folder_name(addon_name))


## Path of the user-tier copy of [param file].
static func user_file(addon_name: String, file: String) -> String:
	return user_dir_for(addon_name).path_join(file)


## The user file's own `{dotted path: value}`, read even when the tier is off; empty when absent or unreadable.
static func user_paths(addon_name: String, file: String) -> Dictionary:
	var path := user_file(addon_name, file)
	if not _file_ok(file) or not FileAccess.file_exists(path):
		return {}
	var res := DotYaml.parse_file(path)
	var out := {}
	if res.ok and res.value is Dictionary:
		_leaf_values(res.value, "", out)
	return out


## Writes [param paths] (`{dotted path: value}`) into the user copy of [param file], keeping its other keys.
## With a [param schema] (the [method DotProfileSet.field] array the editor shows) each top-level key must
## be in it and of its type; without one only yml-safe values are required. `CODE_STATE` while the tier is off.
static func save_user(addon_name: String, file: String, paths: Dictionary, schema: Array = []) -> DotResult:
	if not user_tier_enabled:
		return DotResult.fail(DotError.CODE_STATE, "%s/%s: the user tier is off in this process" % [addon_name, file])
	if not _file_ok(file) or addon_name.strip_edges() == "" or addon_name.contains("/") or addon_name.contains(".."):
		return DotResult.fail(DotError.CODE_INVALID, "bad addon or file name '%s/%s'" % [addon_name, file])
	var scratch: DotProfileSet = DotProfileSet.create(addon_name, "", "addon", schema) if not schema.is_empty() else null
	var tree := {}
	var path := user_file(addon_name, file)
	var had := FileAccess.file_exists(path)
	if had:
		var existing := DotYaml.parse_file(path)
		if not existing.ok:
			return existing.wrap("saving %s" % path)
		if existing.value is Dictionary:
			tree = existing.value
	for key in paths:
		var parts := String(key).split(".")
		if String(key).is_empty() or parts.has(""):
			return DotResult.fail(DotError.CODE_INVALID, "bad key path '%s'" % key)
		var value: Variant = paths[key]
		if not DotProfileSet._finite(value):
			return DotResult.fail(DotError.CODE_INVALID, "%s: NaN or infinity is refused" % key)
		if _is_sensitive(parts[parts.size() - 1], PackedStringArray()):
			return DotResult.fail(DotError.CODE_FORBIDDEN, "%s: secrets are file-only" % key)
		if scratch != null:
			var f := {}
			for e in schema:
				if e["name"] == parts[0]:
					f = e
			if f.is_empty():
				return DotResult.fail(DotError.CODE_INVALID, "unknown key '%s'" % parts[0])
			if parts.size() == 1:
				var checked := scratch._check_field(f, value)
				if checked.has("error"):
					return DotResult.fail(DotError.CODE_INVALID, "%s: %s" % [key, checked["error"]])
				value = checked["value"]
		DotProfileSet._set_path(tree, parts, value)
	var text: Variant = DotProfileRuntime._emit(tree, 0)
	if text == null:
		return DotResult.fail(DotError.CODE_INVALID, "%s holds a value yml cannot carry" % path)
	var dir := DotPaths.ensure_parent_dir(path)
	if not dir.ok:
		return dir
	var wrote := DotPaths.write_text(path, text)
	if not wrote.ok:
		return wrote.wrap("saving %s" % path)
	DotWeb.sync_filesystem()
	DotLog.info(CHANNEL, "saved to user layer", {"addon": addon_name, "file": file, "keys": paths.size()})
	return DotResult.success({"saved": path})


## Removes the user copy of [param file]: back to the tiers below. Value: true when a file was removed.
static func reset_user(addon_name: String, file: String) -> DotResult:
	if not _file_ok(file):
		return DotResult.fail(DotError.CODE_INVALID, "bad file name '%s'" % file)
	var path := user_file(addon_name, file)
	if not FileAccess.file_exists(path):
		return DotResult.success(false)
	if DirAccess.remove_absolute(path) != OK:
		return DotResult.fail(DotError.CODE_IO, "cannot remove %s" % path)
	DotWeb.sync_filesystem()
	DotLog.info(CHANNEL, "user layer reset", {"addon": addon_name, "file": file})
	return DotResult.success(true)


static func _file_ok(file: String) -> bool:
	return file != "" and not file.contains("/") and not file.contains("\\") and not file.contains("..") and file.get_extension() == EXTENSION


static func _leaf_values(tree: Dictionary, prefix: String, out: Dictionary) -> void:
	for k in tree:
		if tree[k] is Dictionary and (tree[k] as Dictionary).size() > 0:
			_leaf_values(tree[k], prefix + str(k) + ".", out)
		else:
			out[prefix + str(k)] = tree[k]


## What an export preset needs so the yml files ship. Godot's exporter only packs resources
## it knows plus what `include_filter` names, so a game that keeps `res://cfg/addons/` ships
## none of it without this; it fails silently, as "no files".
static func export_filter_hint() -> String:
	return "Add `cfg/*` (or `*.yml`) to include_filter in every export preset (Project > Export > Resources > Filters to export non-resource files), or res://cfg/addons/ is left out of the PCK."


## Reads every yml for [param addon_name] over [param defaults]. Value: the merged Dictionary
## (a fresh copy; [param defaults] is never mutated). A missing directory returns the
## defaults. Pass the addon's own defaults only: rows a profile set already merged, passed as
## [param defaults], are overwritten silently. A bad file fails with [constant DotError.CODE_PARSE] (or CODE_IO) naming the file.
static func load_dir(
	addon_name: String,
	defaults: Dictionary = {},
	sensitive: PackedStringArray = PackedStringArray()
) -> DotResult:
	if (
		addon_name.strip_edges().is_empty() or addon_name.contains("/") or addon_name.contains("\\")
		or addon_name.contains(":") or addon_name.contains("..")
	):
		return DotResult.fail(DotError.CODE_INVALID, "Bad addon name for config: '%s'" % addon_name)

	var merged: Dictionary = defaults.duplicate(true)
	var files := PackedStringArray()
	var roots := PackedStringArray()

	# [dir, new_dir]: a legacy dir's file is skipped when the new dir holds it or DotCfgLegacy says no.
	var all_dirs: Array = []
	for d in _candidate_dirs(addon_name):
		all_dirs.append([d, ""])
	for d in _tier_dirs(addon_name, GAME_SUBDIR):
		all_dirs.append([d, ""])
	for d in _tier_dirs(addon_name, USER_SUBDIR):
		all_dirs.append([d, ""])
	var news := _tier_dirs(addon_name, SERVER_SUBDIR)
	var olds := _tier_dirs(addon_name, LEGACY_SERVER_SUBDIR)
	for i in news.size():
		all_dirs.append([olds[i], news[i]])
	for d in news:
		all_dirs.append([d, ""])
	for d in _tier_dirs(addon_name, SERVER_GAME_SUBDIR):
		all_dirs.append([d, ""])
	for pair in all_dirs:
		var dir: String = pair[0]
		var new_dir: String = pair[1]
		if not DirAccess.dir_exists_absolute(dir):
			continue
		roots.append(dir)
		var names := PackedStringArray()
		for f in DirAccess.get_files_at(dir):
			if f.get_extension().to_lower() != EXTENSION:
				continue
			if new_dir != "" and DotCfgLegacy.find(dir.path_join(f), new_dir.path_join(f)) != dir.path_join(f):
				continue
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
			merge(merged, res.value as Dictionary)
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
	return config_root


## Addon directories (`cfg/addons/<addon_underscored>`), weakest root first.
static func _candidate_dirs(addon_name: String) -> PackedStringArray:
	return _tier_dirs(addon_name, SUBDIR)


## One tier's directories (`addons`, `game/<game>`, `server/addons`, `server/game/<game>` or the legacy `server`) for an addon, weakest root first.
static func _tier_dirs(addon_name: String, tier: String, extra_dir: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	if tier == USER_SUBDIR:
		if user_tier_enabled:
			out.append(user_dir_for(addon_name))
		return out
	var sub_root := ""
	if tier == GAME_SUBDIR or tier == SERVER_GAME_SUBDIR:
		if game == "":
			return out
		sub_root = tier.path_join(game)
	var sub := (sub_root if sub_root != "" else tier).path_join(folder_name(addon_name))
	out.append("res://cfg".path_join(sub))
	var exe := OS.get_executable_path().get_base_dir()
	if exe != "":
		out.append(exe.path_join("cfg").path_join(sub))
	out.append("user://cfg".path_join(sub))
	var given := _config_dir_arg()
	if given != "":
		out.append(given.path_join(sub))
	if extra_dir != "" and extra_dir != given:
		out.append(extra_dir.path_join(sub))
	return out


## Deep merge of [param over] into [param into]: maps by key, a list or scalar replaced whole (copied).
static func merge(into: Dictionary, over: Dictionary) -> void:
	for k in over:
		if into.get(k) is Dictionary and over[k] is Dictionary:
			merge(into[k] as Dictionary, over[k] as Dictionary)
		else:
			into[k] = over[k].duplicate(true) if (over[k] is Dictionary or over[k] is Array) else over[k]


## Old private name, kept until callers move to [method merge].
static func _merge(into: Dictionary, over: Dictionary) -> void:
	merge(into, over)


static func _leaf_paths(tree: Dictionary, prefix: String, out: PackedStringArray) -> void:
	for k in tree:
		# A key that is not text, or holds a '.', has no dotted path that reads back.
		if not (k is String or k is StringName) or String(k).contains("."):
			continue
		var p := "%s%s" % [prefix, k]
		if tree[k] is Dictionary:
			_leaf_paths(tree[k] as Dictionary, p + ".", out)
		else:
			out.append(p)


static func _is_sensitive(path: String, extra: PackedStringArray) -> bool:
	var segs := path.split(".")
	var prefix := ""
	for seg in segs:
		prefix = seg if prefix == "" else prefix + "." + seg
		if extra.has(prefix) or extra.has(seg):
			return true
		var words := _words(seg)
		for w in words:
			if w in SECRET_WORDS:
				return true
		if words.size() > 0 and words[words.size() - 1] == "key":
			return true
	return false


## Lower-case words of a key: split on `_`, `-` and a lower-to-upper camelCase step.
static func _words(seg: String) -> PackedStringArray:
	var spaced := ""
	for i in seg.length():
		var c := seg[i]
		if i > 0 and c != c.to_lower() and seg[i - 1] == seg[i - 1].to_lower() and seg[i - 1] != "_" and seg[i - 1] != "-":
			spaced += "_"
		spaced += c
	var out := PackedStringArray()
	for w in spaced.to_lower().replace("-", "_").split("_"):
		if w != "":
			out.append(w)
	return out


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

	# Two leaves can spell the same variable (a_b.c, a.b_c); which one was meant is unknowable.
	var env_owner := {}
	var ambiguous := {}
	for path in leaves:
		var en := _env_name(addon_name, path)
		if env_owner.has(en):
			ambiguous[en] = true
		else:
			env_owner[en] = path
	for en in ambiguous:
		if OS.has_environment(en) and not _warned_ambiguous.has(en):
			_warned_ambiguous[en] = true
			DotLog.warn(CHANNEL, "environment variable names two keys; applied to neither", {"addon": addon_name, "env": en})

	for path in leaves:
		var raw: Variant = null
		var from := ""
		var env_key := _env_name(addon_name, path)
		if OS.has_environment(env_key) and not ambiguous.has(env_key):
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
			elif rest == "" and i + 1 < argv.size() and not String(argv[i + 1]).begins_with("--"):
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
		TYPE_NIL:
			# No type to keep: read it the way a yml file would.
			var parsed := DotYaml.parse("v: " + text)
			if parsed.ok and parsed.value is Dictionary and (parsed.value as Dictionary).has("v"):
				return (parsed.value as Dictionary)["v"]
			return text
		TYPE_INT:
			var t := text.strip_edges()
			if t.is_valid_int():
				return t.to_int()
			if t.is_valid_float():
				var f := t.to_float()
				if is_finite(f) and f == floorf(f) and absf(f) < 9007199254740992.0:
					return int(f)
			return null
		TYPE_FLOAT:
			return float(text) if text.is_valid_float() else null
		TYPE_STRING, TYPE_STRING_NAME:
			return text
		TYPE_ARRAY:
			# Elements keep the type of the default's first element; text when it is empty.
			var proto: Variant = ""
			if (current as Array).size() > 0:
				proto = (current as Array)[0]
			if proto is Dictionary or proto is Array:
				return null
			var items: Array = []
			if text.strip_edges() == "":
				return items
			for part in text.split(","):
				var item: Variant = _coerce(part.strip_edges(), proto)
				if item == null and proto != null:
					return null
				items.append(item)
			return items
	return null
