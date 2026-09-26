@tool
class_name DotAddonApi
extends RefCounted

## Which addon API a build has, and whether a pack that needs one can run on it.
##
## [b]A pack's scripts compile against the HOST's addons.[/b] A game delivered through
## dot-cloud ships its own files and none of the dot-* addons -- those are in the client
## shell and in the server that mount it. So a pack written against a newer dot-net than
## the host has does not fail with anything a person can read: it fails to PARSE, in the
## middle of a load, with an identifier that "is not declared in the current scope". That
## reads as a broken pack, and it is a host that is one release behind.
##
## This turns it into a sentence, asked before a single script in the pack is loaded:
##
## [codeblock]
## This game needs dot-net API level 3 or newer; this server has level 2.
## [/codeblock]
##
## [b]A pack says what it needs in [constant REQUIREMENTS_FILE] at its root[/b] --
## [code]{"addons": {"dot_net": 3, "dot_server": 1}}[/code]. dot-ci writes it when it
## builds a pack (see [method derive]), so no game keeps that list by hand; a game that
## commits one keeps control of it, and the release then checks it is complete.
##
## [b]Why an API LEVEL and not the addon's version.[/b] Two numbers were on offer and
## neither is honest in both places a build is made:
##
## - [b]The release tag's semver[/b], which dot-ci stamps into [code]plugin.cfg[/code]. In
##   a developer checkout every addon is a symlink to a working tree whose plugin.cfg says
##   0.1.0, so a dev host would refuse every pack built by CI and a dev-built pack would
##   claim nothing. And a tag moves for a bug fix that changes no API at all, so "needs
##   dot-net 0.4.1" would refuse a 0.4.0 host that runs the pack perfectly. plugin.cfg is
##   also not a resource, so an exported build does not even carry it.
## - [b]An explicit level, committed in the addon's source[/b], bumped only when the API
##   changes. The same number in a symlinked checkout, a tagged release and an exported
##   build, because it is code. That is the one used here.
##
## [b]The rule for an addon author:[/b] an addon's level lives in
## [code]addons/<addon>/<addon>_api.gd[/code] as [code]const LEVEL[/code] and
## [code]const OLDEST[/code]. Bump LEVEL when you ADD something a game could call -- a
## method, a class, a signal, a field it reads. Raise OLDEST to the new LEVEL when you
## REMOVE or CHANGE something a game could have called, because every pack built before
## that no longer compiles here. An addon with no api file is at [constant BASELINE]: the
## level every addon was at when this scheme began (2026-09-26), so nothing had to be
## touched to adopt it.
##
## The version is still shown when it can be read, in the detail, for the person
## deciding what to upgrade.

# No log channel: every answer here is a DotResult its caller logs with the context this
# class does not have -- which content, which peer, which side.

## The file a pack carries at its root to say what it needs.
const REQUIREMENTS_FILE := "requires.json"

## Where addons live, in a build and in a checkout alike.
const ADDONS_ROOT := "res://addons"

## The level of an addon that declares none. See the class note.
const BASELINE := 1

## Bumped if the shape of [constant REQUIREMENTS_FILE] ever has to change meaning.
const FORMAT := 1

## addon folder -> level, standing in for what this build has.
##
## [b]For a test pretending to be an older build, or a host that knows better.[/b] A
## client and a server in one process share one set of addon files, so "an older client"
## cannot be anything but a claim -- this is where it is made. Empty asks the build.
##
## A value is a level, or `{"level": n, "oldest": m}` to stand in for a build that has
## dropped support for older packs as well.
var overrides: Dictionary = {}

## Script path -> {LEVEL, OLDEST}, so a check that runs on every mount does not load the
## same script twice.
static var _levels_cache: Dictionary = {}


# --- What this build has ---------------------------------------------------

## Whether an addon is in this build at all.
##
## By its folder, which is in an exported build's pack as well as in a checkout. A pack
## asking for an addon a deployment left out is the one requirement no level can meet.
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


## The oldest level whose packs this build still runs, or 0 when it is not installed.
##
## Overriding a level overrides this too, clamped under it: an override exists to be a
## different build, and a build whose oldest supported level is above its own is nonsense.
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
##
## [b]Often absent, and that is fine.[/b] plugin.cfg is not a resource, so an exported
## build leaves it out, and a developer checkout says 0.1.0 whatever it holds. It goes in
## the detail of a refusal, never in the decision.
static func version_of(addon: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load("%s/%s/plugin.cfg" % [ADDONS_ROOT, addon]) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


# --- What a pack needs -----------------------------------------------------

## Reads a requirements document. Returns `{addon: level}`.
##
## Strict about shape and lenient about nothing else: this is read off a pack a server
## handed to a client, so a level that is not a positive integer is a malformed file, not
## a zero.
static func parse(text: String) -> DotResult:
	var json := JSON.new()
	if json.parse(text) != OK:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The game's %s is not valid JSON." % REQUIREMENTS_FILE,
			json.get_error_message()
		)

	if not (json.data is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The game's %s is not a JSON object." % REQUIREMENTS_FILE
		)

	var doc: Dictionary = json.data
	var format: Variant = doc.get("format", FORMAT)
	if not (format is float or format is int) or int(format) > FORMAT:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"This game describes its requirements in a newer way than this build reads.",
			"%s format %s, this build reads %d" % [REQUIREMENTS_FILE, str(format), FORMAT]
		)

	var raw: Variant = doc.get("addons", {})
	if not (raw is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The game's %s has no addon table." % REQUIREMENTS_FILE
		)

	var out := {}
	for key in (raw as Dictionary).keys():
		var addon := str(key)
		var level: Variant = (raw as Dictionary)[key]

		if not _is_addon_name(addon):
			return DotResult.fail(
				DotError.CODE_PARSE,
				"The game's %s names an addon that cannot exist." % REQUIREMENTS_FILE,
				addon
			)

		if not (level is float or level is int) or int(level) < 1 or float(level) != float(int(level)):
			return DotResult.fail(
				DotError.CODE_PARSE,
				"The game's %s gives %s a level that is not a positive whole number."
					% [REQUIREMENTS_FILE, addon],
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
##
## [param who] is the noun a player reads: [code]"server"[/code], [code]"client"[/code],
## [code]"build"[/code]. Every unmet requirement is in the detail; the message is the first
## of them, because a player reads one sentence.
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


# --- What a game uses ------------------------------------------------------

## Every addon a project's own files use, at the level this build has.
##
## [b]Derived from the files, not kept beside them.[/b] A hand-kept list of dependencies
## is a second list, and a second list here is a list that goes stale. This reads every
## script, scene and resource under [param root] -- skipping the addons themselves and
## whatever [param skip_dirs] names -- and finds two things: a global class declared
## under [code]res://addons/<addon>/[/code], by name; and a literal
## [code]res://addons/<addon>/[/code] path. Both are how a pack reaches an addon, and
## both fail to resolve on a host that does not have what they name.
##
## The level recorded is the level THIS build has: "built against". A pack built today
## asks for today's levels, which is conservative -- it may run on an older host that has
## everything it actually calls -- and a game that knows better commits its own file.
## Needs the project imported, so the global class list is populated.
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

	var used := {}
	var word := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
	var literal := RegEx.create_from_string("res://addons/([a-z0-9_]+)/")

	for file in _source_files(root, skip_dirs):
		var text := FileAccess.get_file_as_string(file)
		if text == "":
			continue
		for m in word.search_all(text):
			var token := m.get_string()
			if classes.has(token):
				used[classes[token]] = true
		for m in literal.search_all(text):
			used[m.get_string(1)] = true

	var out := {}
	for addon in used.keys():
		var level := build_level(str(addon))
		if level > 0:
			out[str(addon)] = level
	return out


## Which addons [param requirements] leaves out or overstates, against [method derive].
##
## For a game that commits its own file: a missing addon is a pack that will fail to
## parse on a host without it, and a level above what this build has is a promise the
## build that made the pack cannot keep. Empty is complete.
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
