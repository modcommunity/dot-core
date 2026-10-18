class_name DotContentIndex
extends RefCounted

## What has been mounted that a game could offer, for every consumer.
##
## A map menu, a spawn menu or a weapon catalogue asks [method entries] and never names a pack
## path. dot-cloud fills it on mount; a deployment without dot-cloud has an empty index, which
## is the same "content ships in the build" answer [DotContent] gives.
##
## [b]An instance, not a static class[/b], because it needs signals (the reason [DotLogBus] and
## [DotRegistryBus] exist as carriers). It lives in [DotRegistry] under [constant SERVICE], and
## [method shared] creates and registers one on first call so a catalogue built before the
## first mount and a cloud client that mounts before any catalogue exists find the same object.
## A test replaces it with [code]DotRegistry.register(DotContentIndex.SERVICE, its_own)[/code].
##
## [b]Sessions.[/b] Every pack carries the set of sessions it was mounted for, and the index has
## one current session set by the host. [method entries] answers for the current session only:
## a subscription pack is tagged [constant SESSION_SOLO] and never anything else, so an online
## session never sees it. Nothing is removed at runtime, because a mounted pack cannot be
## unmounted: entries outside the current session are invisible, not gone.

const CHANNEL := "dot.content.index"

const SERVICE := &"dot_content_index"
const SESSION_SOLO := &"solo"
const SESSION_ONLINE := &"online"

## Kinds this build's consumers know. Anything else is kept and offered to nobody (a newer pack
## on an older client is the normal case), logged at DEBUG only.
const KNOWN_KINDS: Array[StringName] = [
	&"map", &"weapon", &"prop", &"npc", &"entity", &"tool", &"sound", &"script", &"addon", &"game",
]

signal pack_added(pack: Dictionary, entries: Array[DotContentEntry])
signal session_changed(session: StringName)

# "<content_id>@<version>" -> pack record. Insertion order is mount order, which is list order.
var _packs: Dictionary = {}
var _entries: Dictionary = {}
var _session: StringName = SESSION_SOLO


## The registered index, created and registered on first call.
static func shared() -> DotContentIndex:
	var existing := DotRegistry.get_service(SERVICE) as DotContentIndex
	if existing != null:
		return existing
	var made := DotContentIndex.new()
	DotRegistry.register(SERVICE, made)
	return made


static func pack_key(p_content_id: String, p_version: String) -> String:
	return "%s@%s" % [p_content_id, p_version]


## Registers a mounted pack. [param info] is
## [code]{content_id, version, prefix, provides, session, source}[/code]. Idempotent: a pack
## already present only gains the session tag. Value on success: the pack's new entries
## ([code]Array[DotContentEntry][/code]; empty when it was already there).
func add_pack(info: Dictionary) -> DotResult:
	var cid := str(info.get("content_id", ""))
	var ver := str(info.get("version", ""))
	var sess := StringName(str(info.get("session", "")))
	if cid == "" or ver == "":
		return DotResult.fail(DotError.CODE_INVALID, "A content pack needs a content_id and a version.")
	if sess != SESSION_SOLO and sess != SESSION_ONLINE:
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown session '%s'." % sess, "use solo or online"
		)
	var provides: Variant = info.get("provides", {})
	if not (provides is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "provides must be a dictionary.")

	var pk := pack_key(cid, ver)
	var made: Array[DotContentEntry] = []
	if _packs.has(pk):
		tag_pack(StringName(cid), ver, sess)
		return DotResult.success(made)

	var pd := provides as Dictionary
	var pack := {
		"content_id": cid,
		"version": ver,
		"prefix": str(info.get("prefix", "")),
		"title": str(pd.get("title", cid)),
		"source": str(info.get("source", "")),
		"runs_code": bool(pd.get("runs_code", false)),
		"sessions": {String(sess): true},
		"keys": PackedStringArray(),
	}
	# A packed array in a Dictionary is copied by `as`, so append to a local and store it back.
	var keys := PackedStringArray()
	var raw_entries: Variant = pd.get("entries", [])
	if raw_entries is Array:
		for d: Variant in (raw_entries as Array):
			if not (d is Dictionary):
				continue
			var e := DotContentEntry.from_dict(d as Dictionary, pack)
			if e == null or _entries.has(e.key):
				continue
			if not KNOWN_KINDS.has(e.kind):
				DotLog.debug(CHANNEL, "kept an entry of a kind nobody here offers", {"key": e.key})
			_entries[e.key] = e
			keys.append(e.key)
			made.append(e)
	pack["keys"] = keys
	_packs[pk] = pack
	DotLog.info(CHANNEL, "pack added", {
		"pack": pk, "session": String(sess), "entries": made.size(),
		"source": pack["source"],
	})
	pack_added.emit(pack, made)
	return DotResult.success(made)


## Adds [param session] to a pack that is already indexed (a solo-mounted pack a server then
## requires at the same id and version: that is the whole of the reuse). Unknown pack: nothing.
func tag_pack(content_id: StringName, version: String, session: StringName) -> void:
	var pk := pack_key(String(content_id), version)
	if not _packs.has(pk):
		DotLog.debug(CHANNEL, "tag for a pack not indexed", {"pack": pk})
		return
	var sessions: Dictionary = (_packs[pk] as Dictionary)["sessions"]
	if sessions.has(String(session)):
		return
	sessions[String(session)] = true
	DotLog.debug(CHANNEL, "pack tagged", {"pack": pk, "session": String(session)})


func set_session(p_session: StringName) -> void:
	if p_session == _session:
		return
	_session = p_session
	DotLog.info(CHANNEL, "session changed", {"session": String(p_session)})
	session_changed.emit(p_session)


func session() -> StringName:
	return _session


## Entries of [param kind] in packs tagged with [param for_session] ("" = the current one),
## in mount order.
func entries(kind: StringName, for_session: StringName = &"") -> Array[DotContentEntry]:
	var want := _session if for_session == &"" else for_session
	var out: Array[DotContentEntry] = []
	for k: String in _entries:
		var e: DotContentEntry = _entries[k]
		if e.kind == kind and e.has_session(want):
			out.append(e)
	return out


## One entry by key regardless of session (tests, tools), or null.
func entry(key: String) -> DotContentEntry:
	return _entries.get(key, null)


## Copies of the pack records visible in [param for_session] ("" = the current one).
func packs(for_session: StringName = &"") -> Array[Dictionary]:
	var want := _session if for_session == &"" else for_session
	var out: Array[Dictionary] = []
	for pk: String in _packs:
		var p: Dictionary = _packs[pk]
		if (p["sessions"] as Dictionary).has(String(want)):
			out.append(p.duplicate(true))
	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("content index, session %s, %d packs, %d entries" % [_session, _packs.size(), _entries.size()])
	for pk: String in _packs:
		var p: Dictionary = _packs[pk]
		var counts: Dictionary = {}
		for k: String in (p["keys"] as PackedStringArray):
			var kind := String((_entries[k] as DotContentEntry).kind)
			counts[kind] = int(counts.get(kind, 0)) + 1
		var kinds: PackedStringArray = []
		for kind: String in counts:
			kinds.append("%s x%d" % [kind, counts[kind]])
		var sess: PackedStringArray = []
		for s: String in (p["sessions"] as Dictionary):
			sess.append(s)
		out.append("  %s \"%s\" [%s] %s%s: %s" % [
			pk, p["title"], ",".join(sess), p["source"],
			" runs code" if p["runs_code"] else "", ", ".join(kinds) if kinds.size() > 0 else "no entries",
		])
	return out
