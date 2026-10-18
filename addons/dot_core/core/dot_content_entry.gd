class_name DotContentEntry
extends RefCounted

## One thing a mounted content pack provides: a map, a weapon, a prop.
##
## Built by [DotContentIndex.add_pack] from the `provides.entries` of a manifest. Consumers
## read the typed fields and [method path]; nobody joins a mount prefix by hand, because the
## prefix (`res://<mount_root>/<content_id>/<version>/`) is an implementation detail of
## dot-cloud that has already changed once.

var kind: StringName = &""
var id: String = ""
## `<content_id>@<version>:<kind>/<id>`. Unique in the process: the same entry id in two
## versions of a pack is two keys, and both coexist because a mounted pack cannot be unmounted.
var key: String = ""
var content_id: String = ""
var version: String = ""
var pack_title: String = ""
var name: String = ""
var category: String = ""
var tags: PackedStringArray = PackedStringArray()
var meta: Dictionary = {}
## `&"subscription"`, `&"server"` or `&"game"`.
var source: StringName = &""
## Shared with the owning pack (the same Dictionary), so [method DotContentIndex.tag_pack]
## reaches every entry without walking them. Keys are session names, values are true.
var sessions: Dictionary = {}
## The entry dictionary as published, unknown fields included.
var raw: Dictionary = {}

var _prefix: String = ""


static func make_key(p_content_id: String, p_version: String, p_kind: String, p_id: String) -> String:
	return "%s@%s:%s/%s" % [p_content_id, p_version, p_kind, p_id]


## Fills an entry from its published dictionary. [param pack] is the index's record of the
## owning pack. Returns null when the dictionary has no usable kind and id.
static func from_dict(d: Dictionary, pack: Dictionary) -> DotContentEntry:
	var k := str(d.get("kind", ""))
	var i := str(d.get("id", ""))
	if k == "" or i == "":
		return null
	var e := DotContentEntry.new()
	e.kind = StringName(k)
	e.id = i
	e.content_id = str(pack.get("content_id", ""))
	e.version = str(pack.get("version", ""))
	e.key = make_key(e.content_id, e.version, k, i)
	e.pack_title = str(pack.get("title", ""))
	e.name = str(d.get("name", i))
	e.category = str(d.get("category", ""))
	var t: Variant = d.get("tags", [])
	if t is Array:
		for x: Variant in (t as Array):
			e.tags.append(str(x))
	var m: Variant = d.get("meta", {})
	if m is Dictionary:
		e.meta = (m as Dictionary).duplicate(true)
	e.source = StringName(str(pack.get("source", "")))
	e.sessions = pack.get("sessions", {})
	e.raw = d.duplicate(true)
	var p := str(pack.get("prefix", ""))
	if p != "" and not p.ends_with("/"):
		p += "/"
	e._prefix = p
	return e


## A path field of the entry (`scene`, `def`, `thumbnail`...) resolved onto the pack's mount,
## or "" when the entry has no such field. The publisher has already refused absolute and
## `..` paths, but a manifest from elsewhere is re-checked here: a path that climbs out of the
## prefix resolves to "" rather than to a file outside the pack.
func path(field: String) -> String:
	var v: Variant = raw.get(field, null)
	if not (v is String) or (v as String) == "":
		return ""
	var rel := v as String
	if rel.begins_with("/") or rel.contains("://") or ("/" + rel + "/").contains("/../"):
		return ""
	return _prefix + rel


func has_session(session: StringName) -> bool:
	return sessions.has(String(session))
