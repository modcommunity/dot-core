extends Node

## Exercises [DotContentIndex]: two packs, two sessions, tag reuse, the session signal, and a
## kind this build does not know.
##
## [codeblock]
## godot --headless --path . res://examples/content_index_selftest.tscn
## [/codeblock]

const SECTIONS := 5
const CHECKS := 32

var _passed := 0
var _failed := 0
var _section_count := 0
var _idx: DotContentIndex


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_idx = DotContentIndex.new()
	_run()


func _provides(title: String, entries: Array) -> Dictionary:
	return {"schema": 1, "title": title, "kinds": [], "entries": entries}


func _run() -> void:
	_line("dot-core content index self-test")
	_line("")

	_test_shared()
	_test_add_and_read()
	_test_sessions()
	_test_tag_reuse()
	_test_unknown_and_invalid()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		_line("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_shared() -> void:
	_section("shared() creates once and registers")
	DotRegistry.unregister(DotContentIndex.SERVICE)
	var a := DotContentIndex.shared()
	_check(a != null, "shared() creates an index")
	_check(DotContentIndex.shared() == a, "and returns the same one afterwards")
	_check(DotRegistry.get_service(DotContentIndex.SERVICE) == a, "registered as dot_content_index")
	var own := DotContentIndex.new()
	DotRegistry.register(DotContentIndex.SERVICE, own)
	_check(DotContentIndex.shared() == own, "a test can replace it")
	DotRegistry.unregister(DotContentIndex.SERVICE)


func _test_add_and_read() -> void:
	_section("Two packs, typed entries and resolved paths")
	var added: Array = []
	_idx.pack_added.connect(func(p: Dictionary, es: Array) -> void: added.append([p, es.size()]))
	var r := _idx.add_pack({
		"content_id": "a/maps", "version": "1.0.0", "prefix": "res://dot_cloud/a/maps/1.0.0",
		"session": &"solo", "source": &"subscription",
		"provides": _provides("Maps", [
			{"kind": "map", "id": "m1", "name": "One", "scene": "maps/m1.tscn", "category": "c", "tags": ["x"]},
			{"kind": "map", "id": "m2", "name": "Two", "scene": "../evil.tscn"},
			{"kind": "weapon", "id": "w1", "def": "w/w1.tres", "meta": {"slot": 2}},
		]),
	})
	_check(r.ok, "add_pack succeeds")
	_check(added.size() == 1 and added[0][1] == 3, "pack_added fired once with three entries")
	_idx.add_pack({
		"content_id": "b/props", "version": "2.0.0", "prefix": "res://dot_cloud/b/props/2.0.0/",
		"session": &"solo", "source": &"subscription",
		"provides": _provides("Props", [{"kind": "prop", "id": "p1", "name": "Crate", "scene": "c.tscn"}]),
	})
	_check(_idx.entries(&"map").size() == 2, "two maps listed")
	_check(_idx.entries(&"prop").size() == 1, "one prop listed")
	var m := _idx.entry("a/maps@1.0.0:map/m1")
	_check(m != null and m.name == "One" and m.category == "c", "entry by key, typed fields")
	_check(m.path("scene") == "res://dot_cloud/a/maps/1.0.0/maps/m1.tscn", "path() joins the prefix")
	_check(m.path("missing") == "", "an absent field is empty")
	_check(_idx.entry("a/maps@1.0.0:map/m2").path("scene") == "", "a path climbing out of the pack is empty")
	_check(_idx.entry("a/maps@1.0.0:weapon/w1").meta.get("slot") == 2, "meta carried")
	_check(m.tags.size() == 1 and m.source == &"subscription", "tags and source carried")
	_check(_idx.describe_lines().size() == 3, "describe_lines has a header and a line per pack")
	_check("\n".join(_idx.describe_lines()).contains(" x1") or "\n".join(_idx.describe_lines()).contains(" x2"), "describe_lines counts entries per kind (not \"no entries\")")


func _test_sessions() -> void:
	_section("Entries are for the current session")
	var seen: Array = []
	_idx.session_changed.connect(func(s: StringName) -> void: seen.append(s))
	_check(_idx.session() == &"solo", "solo by default")
	_idx.set_session(&"online")
	_check(seen == [&"online"], "session_changed fired")
	_check(_idx.entries(&"map").size() == 0, "online sees no solo map")
	_check(_idx.entries(&"map", &"solo").size() == 2, "but a named session still can")
	_check(_idx.packs().size() == 0 and _idx.packs(&"solo").size() == 2, "packs() filters the same way")
	_idx.set_session(&"online")
	_check(seen.size() == 1, "setting the same session fires nothing")


func _test_tag_reuse() -> void:
	_section("tag_pack adds online to a solo pack")
	_idx.tag_pack(&"b/props", "2.0.0", &"online")
	_check(_idx.entries(&"prop").size() == 1, "the tagged pack shows under online")
	_check(_idx.entries(&"map").size() == 0, "the untagged one still does not")
	var r := _idx.add_pack({
		"content_id": "b/props", "version": "2.0.0", "prefix": "x", "session": &"online",
		"provides": _provides("Props", []),
	})
	_check(r.ok and (r.value as Array).size() == 0, "adding it again is idempotent")
	_idx.tag_pack(&"nobody/nothing", "1", &"online")
	_check(_idx.packs().size() == 1, "tagging an unknown pack does nothing")


func _test_unknown_and_invalid() -> void:
	_section("Unknown kinds are kept; bad input fails")
	_idx.add_pack({
		"content_id": "c/new", "version": "1", "prefix": "p", "session": &"online",
		"provides": _provides("New", [{"kind": "hologram", "id": "h", "name": "H", "future_field": 1}]),
	})
	_check(_idx.entry("c/new@1:hologram/h") != null, "an unknown kind is kept")
	_check(_idx.entries(&"map").size() == 0 and _idx.entries(&"prop").size() == 1, "and offered to no known kind")
	_check(_idx.entries(&"hologram").size() == 1, "only to whoever asks for it")
	_check(_idx.entry("c/new@1:hologram/h").raw.get("future_field") == 1, "unknown fields survive in raw")
	_check(not _idx.add_pack({"content_id": "", "version": "1", "session": &"solo", "provides": {}}).ok, "empty id refused")
	var bad := _idx.add_pack({"content_id": "d", "version": "1", "session": &"lan", "provides": {}})
	_check(not bad.ok and bad.error.code == DotError.CODE_INVALID, "unknown session refused as invalid")


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("[%d] %s" % [_section_count, title])


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		_line("  PASS  %s" % label)
	else:
		_failed += 1
		_line("  FAIL  %s" % label)


func _line(s: String) -> void:
	print(s)
