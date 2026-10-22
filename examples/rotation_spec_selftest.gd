extends Node

## Exercises [DotRotationSpec]: string entries, mapping entries with per-entry settings, layering.
##
## [codeblock]
## godot --headless --path . res://examples/rotation_spec_selftest.tscn
## [/codeblock]

const SECTIONS := 4
const CHECKS := 25

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	_run()


func _cands() -> Array:
	return [{"id": "surf_mesa"}, {"id": "surf_ice"}, {"id": "dm_arena"}]


func _run() -> void:
	print("dot-core rotation spec self-test")
	_strings()
	_mappings()
	_layering()
	_bad()
	print("")
	print("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _strings() -> void:
	_section("string entries are unchanged")
	var w := PackedStringArray()
	var spec := DotRotationSpec.normalize({"maps": ["surf_*", "dm_arena", "surf_*"]}, "maps", w, "t")
	var rot: Dictionary = spec["rotations"]["main"]
	_check(rot["entries"] == PackedStringArray(["surf_*", "dm_arena"]), "entries stay a deduped PackedStringArray")
	_check((rot["settings"] as Dictionary).is_empty(), "no settings")
	_check(w.is_empty(), "no warnings")
	_check(DotRotationSpec.settings_for(spec, "main", "surf_ice", _cands()) == {}, "settings_for is empty")
	var ids := DotRotationSpec.expand(rot["entries"], _cands(), {}, PackedStringArray())
	_check(ids == PackedStringArray(["surf_ice", "surf_mesa", "dm_arena"]), "expansion in written order, globs sorted")


func _mappings() -> void:
	_section("mapping entries carry settings")
	var w := PackedStringArray()
	var section := {"maps": [
		"dm_arena",
		{"surf_*": {"waves": "easy"}},
		{"map": "surf_mesa", "waves": "hard", "profile": "night"},
	]}
	var spec := DotRotationSpec.normalize(section, "maps", w, "t")
	var rot: Dictionary = spec["rotations"]["main"]
	_check(rot["entries"] == PackedStringArray(["dm_arena", "surf_*", "surf_mesa"]), "patterns join entries")
	_check(w.is_empty(), "no warnings")
	var ids := DotRotationSpec.expand(rot["entries"], _cands(), {}, PackedStringArray())
	_check(ids == PackedStringArray(["dm_arena", "surf_ice", "surf_mesa"]), "mapping patterns expand like strings")
	_check(DotRotationSpec.settings_for(spec, "main", "surf_ice", _cands()) == {"waves": "easy"}, "single-key form: glob settings")
	_check(DotRotationSpec.settings_for(spec, "main", "surf_mesa", _cands()) == {"waves": "hard", "profile": "night"}, "later entry wins, keys merge")
	_check(DotRotationSpec.settings_for(spec, "main", "dm_arena", _cands()) == {}, "string entry has none")
	_check(DotRotationSpec.settings_for(spec, "nope", "surf_ice", _cands()) == {}, "unknown rotation has none")
	var named := DotRotationSpec.normalize({"rotations": {"night": {"mode": "cycle", "maps": [{"id": "dm_arena", "waves": 3}]}}}, "maps", w, "t")
	_check(DotRotationSpec.settings_for(named, "night", "dm_arena", _cands()) == {"waves": 3}, "named rotation with maps: block")
	_check(DotRotationSpec.mode_of(named, "night") == "cycle", "mode still read")


func _layering() -> void:
	_section("layering replaces entries and settings together")
	var w := PackedStringArray()
	var base := DotRotationSpec.normalize({"maps": [{"surf_*": {"waves": "easy"}}]}, "maps", w, "base")
	var over := DotRotationSpec.normalize({"maps": ["dm_arena"]}, "maps", w, "over")
	var merged := DotRotationSpec.layer([base, over])
	_check((merged["rotations"]["main"]["entries"] as PackedStringArray) == PackedStringArray(["dm_arena"]), "a list replaces a list")
	_check(DotRotationSpec.settings_for(merged, "main", "surf_ice", _cands()) == {}, "the old settings went with the old list")
	var kept := DotRotationSpec.layer([base, DotRotationSpec.normalize({"rotations": {"main": {"mode": "cycle"}}}, "maps", w, "m")])
	_check(DotRotationSpec.settings_for(kept, "main", "surf_ice", _cands()) == {"waves": "easy"}, "a mode-only layer keeps the settings")
	_check(DotRotationSpec.mode_of(kept, "main") == "cycle", "and sets the mode")
	var only := DotRotationSpec.layer([DotRotationSpec.normalize({"maps": [{"surf_ice": {"waves": "x"}}]}, "maps", w, "o")])
	_check(DotRotationSpec.settings_for(only, "main", "surf_ice", _cands()) == {"waves": "x"}, "a single layer keeps settings")


func _bad() -> void:
	_section("malformed mapping entries")
	var w := PackedStringArray()
	var spec := DotRotationSpec.normalize({"maps": [{"a": 1, "b": 2}, "dm_arena"]}, "maps", w, "t")
	_check(w.size() == 1 and w[0].contains("rotation entry"), "a map with no pattern warns")
	_check(spec["rotations"]["main"]["entries"] == PackedStringArray(["dm_arena"]), "and is skipped")
	var w2 := PackedStringArray()
	var s2 := DotRotationSpec.normalize({"maps": [{"map": "  "}]}, "maps", w2, "t")
	_check((s2["rotations"]["main"]["entries"] as PackedStringArray).is_empty(), "an empty pattern is skipped")
	var s3 := DotRotationSpec.normalize({"maps": "dm_arena"}, "maps", w2, "t")
	_check(s3["rotations"]["main"]["entries"] == PackedStringArray(["dm_arena"]), "a bare string still works")
	_check(DotRotationSpec.normalize({}, "maps", w2, "t")["rotations"].is_empty(), "an empty section has no rotations")
	_check(w2.is_empty(), "no warnings for those")


func _section(title: String) -> void:
	_section_count += 1
	print("")
	print("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
