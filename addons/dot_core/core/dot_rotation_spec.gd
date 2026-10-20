class_name DotRotationSpec
extends RefCounted

## What an operator's rotation file says, and the one matcher that turns its entries into ids.
##
## [b]Shared by maps.yml (dot-map) and games.yml (dot-server-deploy), and that is the point.[/b]
## Both files name a list of things to play, with named rotations, a mode and a cooldown, and
## both accept the same entry shapes. A second copy of the matching is a second place where
## `mg-*` means something different, so the thing being listed is abstract here: a
## [i]candidate[/i] is a Dictionary `{"id": "surf_mesa", "ref": "owner/surf_mesa"}` (`ref` is
## optional) and the caller supplies the installed ones.
##
## A section (one level of the file) normalises to
## `{"rotation": String, "mode": String, "cooldown": int (-1 unset), "rotations": {name: {"mode": String, "cooldown": int, "entries": PackedStringArray}}}`.
## A plain list under [param list_key] at the section's level is shorthand for a rotation
## named `main`; if the section also defines `rotations: main`, that wins and a warning is
## returned.

const CHANNEL := "core.rotation"
const MAIN := "main"
const MODES := ["random", "cycle"]


## One file section, normalised. The value is the spec Dictionary above; [param warnings]
## collects what the caller should log.
static func normalize(section: Dictionary, list_key: String, warnings: PackedStringArray, where: String = "") -> Dictionary:
	var spec := {"rotation": "", "mode": "", "cooldown": -1, "rotations": {}, "commands": {"names": {}}}
	if section.has("commands"):
		spec["commands"] = _commands(section["commands"], warnings, where)
	if section.has("rotation"):
		spec["rotation"] = str(section["rotation"]).strip_edges()
	if section.has("mode"):
		spec["mode"] = _mode(section["mode"], warnings, where)
	if section.has("cooldown"):
		spec["cooldown"] = maxi(int(section["cooldown"]), 0)

	var named: Variant = section.get("rotations", {})
	if named is Dictionary:
		for key: Variant in (named as Dictionary):
			var body: Variant = (named as Dictionary)[key]
			var rot := {"mode": "", "cooldown": -1, "entries": PackedStringArray()}
			if body is Dictionary:
				var b := body as Dictionary
				if b.has("mode"):
					rot["mode"] = _mode(b["mode"], warnings, where)
				if b.has("cooldown"):
					rot["cooldown"] = maxi(int(b["cooldown"]), 0)
				rot["entries"] = _entries(b.get(list_key, []))
			elif body is Array:
				rot["entries"] = _entries(body)
			(spec["rotations"] as Dictionary)[str(key)] = rot
	elif section.has("rotations"):
		warnings.append("%srotations: must be a map of names to lists" % _at(where))

	if section.has(list_key):
		var shorthand := {"mode": "", "cooldown": -1, "entries": _entries(section[list_key])}
		if (spec["rotations"] as Dictionary).has(MAIN):
			warnings.append("%s%s: and rotations: main are both set; rotations: main wins" % [_at(where), list_key])
		else:
			(spec["rotations"] as Dictionary)[MAIN] = shorthand
	return spec


## Layers specs, weakest first. Scalars override; a rotation of the same name has its entries
## replaced (a list replaces a list) and its own mode/cooldown merged.
static func layer(specs: Array) -> Dictionary:
	var out := {"rotation": "", "mode": "", "cooldown": -1, "rotations": {}, "commands": {"names": {}}}
	for s: Variant in specs:
		var spec := s as Dictionary
		var cmds: Dictionary = spec.get("commands", {})
		if cmds.has("prefix"):
			(out["commands"] as Dictionary)["prefix"] = cmds["prefix"]
		for role: Variant in (cmds.get("names", {}) as Dictionary):
			# A list of names replaces the list below it, like any other list here.
			((out["commands"] as Dictionary)["names"] as Dictionary)[role] = cmds["names"][role]
		for k in ["rotation", "mode"]:
			if str(spec.get(k, "")) != "":
				out[k] = spec[k]
		if int(spec.get("cooldown", -1)) >= 0:
			out["cooldown"] = spec["cooldown"]
		for name: Variant in (spec.get("rotations", {}) as Dictionary):
			var incoming: Dictionary = (spec["rotations"] as Dictionary)[name]
			var have: Dictionary = (out["rotations"] as Dictionary).get(name, {"mode": "", "cooldown": -1, "entries": PackedStringArray()})
			var merged := have.duplicate()
			if str(incoming.get("mode", "")) != "":
				merged["mode"] = incoming["mode"]
			if int(incoming.get("cooldown", -1)) >= 0:
				merged["cooldown"] = incoming["cooldown"]
			# A rotation that only sets a mode keeps the list below it.
			if not (incoming["entries"] as PackedStringArray).is_empty() or not have.has("entries"):
				merged["entries"] = incoming["entries"]
			(out["rotations"] as Dictionary)[name] = merged
	return out


## Whether a file key (`game-g2gfast`, `gamemann/game-g2gfast`) names [param game].
## Id or name half, as content.yml matches games.
static func key_matches(key: String, game: String) -> bool:
	if key == game:
		return true
	return key.get_slice("/", key.get_slice_count("/") - 1) == game.get_slice("/", game.get_slice_count("/") - 1) \
		and (not key.contains("/") or not game.contains("/"))


## The rotation to play: [param requested] if the spec has it, else the spec's `rotation:`,
## else `main`, else the only one there is. "" when the spec lists nothing.
static func active_name(spec: Dictionary, requested: String = "") -> String:
	var rots: Dictionary = spec.get("rotations", {})
	for n in [requested, str(spec.get("rotation", "")), MAIN]:
		if str(n) != "" and rots.has(str(n)):
			return str(n)
	return str(rots.keys()[0]) if rots.size() == 1 else ""


static func mode_of(spec: Dictionary, name: String) -> String:
	var m := str(((spec.get("rotations", {}) as Dictionary).get(name, {}) as Dictionary).get("mode", ""))
	if m == "":
		m = str(spec.get("mode", ""))
	return m if m != "" else "random"


static func cooldown_of(spec: Dictionary, name: String, fallback: int) -> int:
	var c := int(((spec.get("rotations", {}) as Dictionary).get(name, {}) as Dictionary).get("cooldown", -1))
	if c < 0:
		c = int(spec.get("cooldown", -1))
	return c if c >= 0 else fallback


## Expands [param entries] against [param candidates] (`{"id", "ref"}`), in written order,
## each glob's matches sorted by id, no repeats.
##
## Entry shapes: `owner/map` (the candidate's ref), a bare name or a glob (`surf_*`, `*`,
## matched against the id), `owner/*` (every candidate of that owner) and
## `owner/collection/*` (every member of [param collections]`[owner/collection]`, an array of
## `owner/map` refs the caller read from wherever collections are published). Comparison is
## case-insensitive. Entries that matched nothing are appended to [param unmatched] so the
## caller can WARN with its own words.
static func expand(entries: PackedStringArray, candidates: Array, collections: Dictionary,
		unmatched: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for raw in entries:
		var entry := raw.strip_edges().to_lower()
		var found: Array = []
		if entry.ends_with("/*") and entry.count("/") == 2:
			var members := PackedStringArray()
			for m: Variant in (collections.get(entry.trim_suffix("/*"), []) as Array):
				members.append(str(m).to_lower())
			for c: Dictionary in candidates:
				if members.has(_ref(c)) or (str(c.get("ref", "")) == "" and _members_name(members, str(c["id"]))):
					found.append(str(c["id"]))
		elif entry.contains("/"):
			for c: Dictionary in candidates:
				var ref := _ref(c)
				var owned := str(c.get("ref", "")) != ""
				# A candidate with no known owner can only be named exactly (`owner/map`): letting
				# `owner/*` claim it would put every ownerless map in every owner's wildcard.
				var name_part := entry.get_slice("/", 1)
				if (owned and ref.matchn(entry)) or (not owned and not name_part.contains("*") and not name_part.contains("?") and str(c["id"]).matchn(name_part)):
					found.append(str(c["id"]))
		else:
			for c: Dictionary in candidates:
				if str(c["id"]).matchn(entry):
					found.append(str(c["id"]))
		if found.is_empty():
			unmatched.append(raw)
			continue
		found.sort()
		for id: Variant in found:
			if not out.has(str(id)):
				out.append(str(id))
	return out


static func _ref(c: Dictionary) -> String:
	return str(c.get("ref", "")).to_lower()


static func _members_name(members: PackedStringArray, id: String) -> bool:
	for m in members:
		if m.get_slice("/", 1).to_lower() == id.to_lower():
			return true
	return false


static func _entries(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if v is Array:
		for e: Variant in (v as Array):
			var s := str(e).strip_edges()
			if s != "" and not out.has(s):
				out.append(s)
	elif v != null and str(v).strip_edges() != "":
		out.append(str(v).strip_edges())
	return out


static func _mode(v: Variant, warnings: PackedStringArray, where: String) -> String:
	var m := str(v).strip_edges().to_lower()
	if m == "sequential":
		m = "cycle"
	if not MODES.has(m):
		warnings.append("%smode must be random or cycle, not '%s'; random is used" % [_at(where), m])
		return "random"
	return m


static func _at(where: String) -> String:
	return where + ": " if where != "" else ""


## A `commands:` block: `prefix:` (a string, "" allowed, absent means the code's own) and
## `names:` (role to a name or a list of names, the first being the one help and hints show and
## the rest aliases). Normalised to `{"prefix": String (only if written), "names": {role: PackedStringArray}}`.
## One leading "!" or "/" is removed (it is the chat prefix, set by `prefix:`). A name that is
## then not lowercase letters, digits and underscores is dropped with a warning,
## because it could never be typed after a chat prefix.
static func _commands(value: Variant, warnings: PackedStringArray, where: String) -> Dictionary:
	var out := {"names": {}}
	if not value is Dictionary:
		warnings.append("%scommands: must be a map" % _at(where))
		return out
	var block := value as Dictionary
	if block.has("prefix"):
		out["prefix"] = str(block["prefix"]).strip_edges()
	var names: Variant = block.get("names", {})
	if not names is Dictionary:
		warnings.append("%scommands: names: must be a map of role to name or list of names" % _at(where))
		return out
	for role: Variant in (names as Dictionary):
		var raw: Variant = (names as Dictionary)[role]
		var list: Array = raw if raw is Array else [raw]
		var good := PackedStringArray()
		for n: Variant in list:
			var text := str(n).strip_edges()
			# An owner writes the name as players type it ("!rtv", "/rtv"). The chat prefix is
			# `prefix:`, not part of the name, so one leading "!" or "/" is taken off rather
			# than the whole name dropped for it.
			if text.begins_with("!") or text.begins_with("/"):
				text = text.substr(1).strip_edges()
			var ok := text != ""
			for i in text.length():
				var c := text.unicode_at(i)
				if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
					ok = false
			if ok:
				good.append(text)
			else:
				warnings.append("%scommands: '%s' is not a usable command name (lowercase letters, digits, underscore)" % [_at(where), text])
		if not good.is_empty():
			(out["names"] as Dictionary)[str(role)] = good
	return out
