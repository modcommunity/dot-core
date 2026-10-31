@tool
class_name DotAddonApi
extends RefCounted

## Which addon API a build has, and whether a pack that needs one can run on it.
## A pack compiles against the HOST's addons, so a newer-than-host pack fails to parse mid-load; this asks first and says "needs dot-net API level 3; this server has 2".
## Levels live in each addon's [code]<addon>_api.gd[/code] (LEVEL bumped on add, OLDEST raised on remove); a checkout's plugin.cfg version is no honest number.

# No log channel: every answer here is a DotResult its caller logs with the context this
# class does not have -- which content, which peer, which side.

## The file a pack carries at its root to say what it needs.
const REQUIREMENTS_FILE := "requires.json"

## The file a game commits to ask LESS of an addon than it was built against, because it
## asks the host for the newer API before using it. See [method apply_floors].
const FLOOR_FILE := "requires.floor.json"

## The file a project commits to name addons it uses where no script or scene names a class
## or path (config only). [method derive] counts them as used. Shape: {"format": 1, "uses": ["x"]}.
const USES_FILE := "requires.uses.json"

## Where addons live, in a build and in a checkout alike.
const ADDONS_ROOT := "res://addons"

## The level of an addon that declares none. See the class note.
const BASELINE := 1

## Bumped if the shape of [constant REQUIREMENTS_FILE] ever has to change meaning.
const FORMAT := 1

## addon folder -> level, standing in for what this build has.
## For a test pretending to be an older build; empty asks the build. A value is a level or [code]{"level": n, "oldest": m}[/code].
var overrides: Dictionary = {}

## Script path -> {LEVEL, OLDEST}, so a check that runs on every mount does not load the
## same script twice.
static var _levels_cache: Dictionary = {}



## Whether an addon is in this build at all, by folder (present in exports too).
## A pack asking for an addon a deployment left out is the one requirement no level can meet.
static func installed(addon: String) -> bool:
	if not _is_addon_name(addon):
		return false
	return DirAccess.dir_exists_absolute("%s/%s" % [ADDONS_ROOT, addon])


## The path of the file an addon's level lives in.
static func api_script_path(addon: String) -> String:
	return "%s/%s/%s_api.gd" % [ADDONS_ROOT, addon, addon]


## What a person calls the addon: the repository name, `dot-net` for `dot_net`.
static func display_name(addon: String) -> String:
	return addon.replace("_", "-")


## This build's level of an addon, or 0 when it is not installed.
func level_of(addon: String) -> int:
	if overrides.has(addon):
		var o: Variant = overrides[addon]
		return int((o as Dictionary).get("level", 0)) if o is Dictionary else int(o)
	return build_level(addon)


## The oldest level whose packs this build still runs, or 0 when not installed.
## An override clamps it under the overridden level: an oldest above the level is nonsense.
func oldest_of(addon: String) -> int:
	var level := level_of(addon)
	if level <= 0:
		return 0
	var o: Variant = overrides.get(addon)
	if o is Dictionary and (o as Dictionary).has("oldest"):
		return clampi(int((o as Dictionary)["oldest"]), 1, level)
	return mini(build_oldest(addon), level)


## What the addon's own source says, ignoring [member overrides].
static func build_level(addon: String) -> int:
	if not installed(addon):
		return 0
	return int(_declared(addon).get("LEVEL", BASELINE))


static func build_oldest(addon: String) -> int:
	if not installed(addon):
		return 0
	return int(_declared(addon).get("OLDEST", 1))


static func _declared(addon: String) -> Dictionary:
	var path := api_script_path(addon)

	if _levels_cache.has(path):
		return _levels_cache[path]

	var found := {}

	if ResourceLoader.exists(path):
		var script := load(path) as Script
		if script != null:
			var constants := script.get_script_constant_map()
			if constants.has("LEVEL"):
				found["LEVEL"] = maxi(1, int(constants["LEVEL"]))
			if constants.has("OLDEST"):
				found["OLDEST"] = maxi(1, int(constants["OLDEST"]))

	_levels_cache[path] = found
	return found


## The addon's release version, when this build carries its plugin.cfg. For a person.
## Often absent (exports omit plugin.cfg); it goes in a refusal's detail, never the decision.
static func version_of(addon: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load("%s/%s/plugin.cfg" % [ADDONS_ROOT, addon]) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))



## Reads a requirements document. Returns `{addon: level}`.
## [param file_name] is only what messages call it. Strict on shape: a level that is not a positive integer is malformed, not zero.
static func parse(text: String, file_name: String = REQUIREMENTS_FILE) -> DotResult:
	var json := JSON.new()
	if json.parse(text) != OK:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The game's %s is not valid JSON." % file_name,
			json.get_error_message()
		)

	if not (json.data is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The game's %s is not a JSON object." % file_name
		)

	var doc: Dictionary = json.data
	var format: Variant = doc.get("format", FORMAT)
	if not (format is float or format is int) or int(format) > FORMAT:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"This game describes its requirements in a newer way than this build reads.",
			"%s format %s, this build reads %d" % [file_name, str(format), FORMAT]
		)

	var raw: Variant = doc.get("addons", {})
	if not (raw is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The game's %s has no addon table." % file_name
		)

	var out := {}
	for key in (raw as Dictionary).keys():
		var addon := str(key)
		var level: Variant = (raw as Dictionary)[key]

		if not _is_addon_name(addon):
			return DotResult.fail(
				DotError.CODE_PARSE,
				"The game's %s names an addon that cannot exist." % file_name,
				addon
			)

		if not (level is float or level is int) or int(level) < 1 or float(level) != float(int(level)):
			return DotResult.fail(
				DotError.CODE_PARSE,
				"The game's %s gives %s a level that is not a positive whole number."
					% [file_name, addon],
				str(level)
			)

		out[addon] = int(level)

	return DotResult.success(out)


## The document for a set of requirements, sorted so two builds of one tree write the
## same bytes.
static func encode(requirements: Dictionary) -> String:
	var names: Array = requirements.keys()
	names.sort()

	var addons := {}
	for name in names:
		addons[str(name)] = int(requirements[name])

	return JSON.stringify({"format": FORMAT, "addons": addons}, "  ", false) + "\n"


## Whether this build can run something that needs [param requirements].
## [param who] is the noun a player reads. Every unmet requirement is in the detail; the message is the first.
func check(requirements: Dictionary, who: String = "build") -> DotResult:
	var problems: Array[DotError] = []

	var names: Array = requirements.keys()
	names.sort()

	for name in names:
		var addon := str(name)
		var need := int(requirements[name])
		var have := level_of(addon)

		if have <= 0:
			problems.append(DotError.make(
				DotError.CODE_VERSION,
				"This game needs %s, and this %s does not have it."
					% [display_name(addon), who],
				"%s>=%d: not installed" % [addon, need]
			))
			continue

		if need > have:
			problems.append(DotError.make(
				DotError.CODE_VERSION,
				"This game needs %s API level %d or newer; this %s has level %d."
					% [display_name(addon), need, who, have],
				"%s>=%d: have %d%s" % [addon, need, have, _version_note(addon)]
			))
			continue

		var oldest := oldest_of(addon)
		if need < oldest:
			problems.append(DotError.make(
				DotError.CODE_VERSION,
				"This game was built for %s API level %d, which this %s no longer supports (it supports %d to %d)."
					% [display_name(addon), need, who, oldest, have],
				"%s>=%d: have %d, oldest supported %d%s"
					% [addon, need, have, oldest, _version_note(addon)]
			))

	if problems.is_empty():
		return DotResult.success(requirements)

	var details := PackedStringArray()
	for p in problems:
		details.append(p.detail)

	var first := problems[0]
	var err := DotError.make(first.code, first.message, "; ".join(details))
	err.context = {"unmet": problems.size()}
	return DotResult.failure(err)


## [method parse] and then [method check], for a caller holding the file's text.
func check_text(text: String, who: String = "build") -> DotResult:
	var parsed := parse(text)
	if not parsed.ok:
		return parsed
	return check(parsed.value as Dictionary, who)


## [method check] against a pack already mounted at [param prefix], when it carries a
## requirements file. A pack without one needs nothing that can be checked.
func check_mounted(prefix: String, who: String = "build") -> DotResult:
	var path := prefix.trim_suffix("/") + "/" + REQUIREMENTS_FILE
	if not FileAccess.file_exists(path):
		return DotResult.success({})
	return check_text(FileAccess.get_file_as_string(path), who)


static func _version_note(addon: String) -> String:
	var v := version_of(addon)
	return "" if v == "" else " (version %s)" % v


static func _is_addon_name(addon: String) -> bool:
	if addon == "" or addon.length() > 64:
		return false
	for i in addon.length():
		var c := addon.unicode_at(i)
		var ok := (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95
		if not ok:
			return false
	return true



## Every addon a project's own files use, at the level this build has. Needs the project imported.
## Derived from files, not a hand-kept list that goes stale: a global class or literal [code]res://addons/<addon>/[/code] path under [param root].
## The level is "built against", which is conservative; [constant FLOOR_FILE] lowers it for guarded addons.
static func derive(
	root: String = "res://",
	skip_dirs: PackedStringArray = PackedStringArray(["addons", "examples", "tools", ".godot", ".github", "screenshots"])
) -> Dictionary:
	var classes := {}
	for entry in ProjectSettings.get_global_class_list():
		var path := str(entry.get("path", ""))
		var addon := _addon_of(path)
		if addon != "":
			classes[str(entry.get("class", ""))] = addon

	var scan := _scan(root, skip_dirs, classes)
	for addon in declared_uses(root):
		scan.hard[addon] = true
	var own := own_addon(root)
	var out := {}
	for addon in scan.hard.keys():
		if addon == own:
			continue
		var level := build_level(str(addon))
		if level > 0:
			out[str(addon)] = level
	return out


## The addon a project of that name provides itself ("zz-medieval-weapons" is addons/zz_medieval_weapons), or "".
## A pack must not require the addon it carries: no server has it installed, so the pack is refused. Decided by name because a copied dependency (Windows) looks like owned source.
static func own_addon(root: String = "res://") -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_join(root, "project.godot")) != OK:
		return ""
	var addon := str(cfg.get_value("application", "config/name", "")).to_lower().replace("-", "_")
	return addon if _is_addon_name(addon) and DirAccess.dir_exists_absolute(_join(_join(root, ADDONS_ROOT.trim_prefix("res://")), addon)) else ""


## The addons [param root]'s [constant USES_FILE] names; empty when absent or unreadable.
static func declared_uses(root: String = "res://") -> PackedStringArray:
	var out := PackedStringArray()
	var path := _join(root, USES_FILE)
	if not FileAccess.file_exists(path):
		return out
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return out
	var raw: Variant = (json.data as Dictionary).get("uses", [])
	if raw is Array:
		for item in raw:
			if item is String and _is_addon_name(item):
				out.append(item)
	return out


## Addons a project reaches only behind a presence check, so a host without them still runs the game.
## Optional when every file naming it uses only a literal path in [code]load()[/code] (no class name, no preload) after an existence or level check, per file.
## They stay out of requires.json, or a missing add-on would refuse the whole game before it starts.
static func derive_optional(
	root: String = "res://",
	skip_dirs: PackedStringArray = PackedStringArray(["addons", "examples", "tools", ".godot", ".github", "screenshots"])
) -> Dictionary:
	var classes := {}
	for entry in ProjectSettings.get_global_class_list():
		var addon := _addon_of(str(entry.get("path", "")))
		if addon != "":
			classes[str(entry.get("class", ""))] = addon
	var scan := _scan(root, skip_dirs, classes)
	var own := own_addon(root)
	var out := {}
	for addon in scan.soft.keys():
		if not scan.hard.has(addon) and addon != own:
			var level := build_level(str(addon))
			if level > 0:
				out[str(addon)] = level
	return out


## {hard: {addon: true}, soft: {addon: true}} for [method derive] and [method derive_optional].
static func _scan(root: String, skip_dirs: PackedStringArray, classes: Dictionary) -> Dictionary:
	var hard := {}
	var soft := {}
	var word := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
	var literal := RegEx.create_from_string("res://addons/([a-z0-9_]+)/")
	var presence := RegEx.create_from_string("\\b(?:ResourceLoader\\.exists|FileAccess\\.file_exists|DirAccess\\.dir_exists_absolute|DotAddonApi\\.(?:installed|build_level))\\s*\\(")

	for file in _source_files(root, skip_dirs):
		var text := FileAccess.get_file_as_string(file)
		if text == "":
			continue
		var is_script := file.get_extension() == "gd"
		if is_script:
			text = _strip_comments(text)
		var guarded_file := is_script and presence.search(text) != null
		for m in word.search_all(text):
			var token := m.get_string()
			if classes.has(token):
				hard[classes[token]] = true
		for m in literal.search_all(text):
			var addon := m.get_string(1)
			var line_start := text.rfind("\n", m.get_start()) + 1
			var before := text.substr(line_start, m.get_start() - line_start)
			if guarded_file and not before.contains("preload"):
				soft[addon] = true
			else:
				hard[addon] = true
	return {"hard": hard, "soft": soft}


## [param text] with each line's trailing GDScript comment removed. Tracks quotes so a
## `#` inside a string (a colour, a path) stays.
static func _strip_comments(text: String) -> String:
	var lines := text.split("\n")
	for i in lines.size():
		var line := lines[i]
		if not line.contains("#"):
			continue
		var quote := ""
		for j in line.length():
			var c := line[j]
			if quote != "":
				if c == quote and line[j - 1] != "\\":
					quote = ""
			elif c == "\"" or c == "'":
				quote = c
			elif c == "#":
				lines[i] = line.substr(0, j)
				break
	return "\n".join(lines)


## Which addons [param requirements] leaves out or overstates, against [method derive].
## For a game committing its own file; empty is complete.
static func audit(requirements: Dictionary, derived: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var names: Array = derived.keys()
	names.sort()
	for addon in names:
		if not requirements.has(addon):
			out.append("%s is used and not declared" % addon)
		elif int(requirements[addon]) > int(derived[addon]):
			out.append("%s is declared at %d and this build has %d"
				% [addon, int(requirements[addon]), int(derived[addon])])
	return out



## [param derived] with each addon [param floors] names lowered to its floor.
## A game that guards a newer call behind [code]build_level[/code] would otherwise be refused by an older host before the guard runs.
## A floor at or above the derived level changes nothing; an unused addon is not added.
static func apply_floors(derived: Dictionary, floors: Dictionary) -> Dictionary:
	var out := derived.duplicate()
	for key in floors.keys():
		var addon := str(key)
		if out.has(addon):
			out[addon] = mini(int(out[addon]), int(floors[key]))
	return out


## Which of a game's floors cannot be honoured, against [method derive] and [method guarded]; empty is sound.
## Unsound: an addon the game does not use; a floor above this build; below its OLDEST; or an addon no file asks the level of.
## [param oldest] stands in for [method build_oldest] per addon, for a test.
static func floor_audit(
	floors: Dictionary, derived: Dictionary, guards: Dictionary, oldest: Dictionary = {}
) -> PackedStringArray:
	var out := PackedStringArray()
	var names: Array = floors.keys()
	names.sort()
	for key in names:
		var addon := str(key)
		var floor_level := int(floors[key])

		if not derived.has(addon):
			out.append("%s has a floor and the game does not use it" % addon)
			continue

		var have := int(derived[addon])
		if floor_level > have:
			out.append("%s has a floor of %d, above the %d this build has" % [addon, floor_level, have])
			continue

		var lowest := int(oldest[addon]) if oldest.has(addon) else build_oldest(addon)
		if floor_level < lowest:
			out.append("%s has a floor of %d, below %d, the oldest level this build supports; a host at this build's level would refuse the pack"
				% [addon, floor_level, lowest])
			continue

		if floor_level < have and not guards.has(addon):
			out.append('%s has a floor of %d and no file asks the host for its level (DotAddonApi.build_level("%s")), so nothing runs an older path'
				% [addon, floor_level, addon])
	return out


## Every addon a project's own files ask the host's level of, by name:
## `build_level("dot_ui")` or `level_of("dot_ui")`. The evidence [method floor_audit] wants
## that a floor has an older path behind it. Same files as [method derive].
static func guarded(
	root: String = "res://",
	skip_dirs: PackedStringArray = PackedStringArray(["addons", "examples", "tools", ".godot", ".github", "screenshots"])
) -> Dictionary:
	var out := {}
	var ask := RegEx.create_from_string("\\b(?:build_level|level_of)\\s*\\(\\s*\"([a-z0-9_]+)\"")
	for file in _source_files(root, skip_dirs):
		for m in ask.search_all(FileAccess.get_file_as_string(file)):
			out[m.get_string(1)] = true
	return out


static func _addon_of(path: String) -> String:
	var prefix := ADDONS_ROOT + "/"
	if not path.begins_with(prefix):
		return ""
	var rest := path.substr(prefix.length())
	var slash := rest.find("/")
	return rest.substr(0, slash) if slash > 0 else ""


static func _source_files(root: String, skip_dirs: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var pending: Array[String] = [root]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.include_hidden = false
		for sub in dir.get_directories():
			if skip_dirs.has(sub):
				continue
			pending.append(_join(dir_path, sub))
		for file in dir.get_files():
			var ext := file.get_extension()
			if ext == "gd" or ext == "tscn" or ext == "tres":
				out.append(_join(dir_path, file))

	out.sort()
	return out


## `res://` already ends in a separator and every other directory does not; a join that
## assumed either produced `res:/game` for the root, which opens nothing and found no file.
static func _join(dir_path: String, name: String) -> String:
	return dir_path + name if dir_path.ends_with("/") else dir_path + "/" + name


func describe(addons: PackedStringArray) -> Dictionary:
	var out := {}
	for addon in addons:
		out[addon] = {
			"level": level_of(addon),
			"oldest": oldest_of(addon),
			"version": version_of(addon),
			"overridden": overrides.has(addon),
		}
	return out
