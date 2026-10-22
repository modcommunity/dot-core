extends Node

## Exercises [DotAddonConfig]: `cfg/addons/<name>/*.yml` read in file-name order over defaults.
##
## [codeblock]
## godot --headless --path . res://examples/addon_config_selftest.tscn
## [/codeblock]

const SECTIONS := 7
const CHECKS := 63
const NAME := "selftest-addon"

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-core addon config self-test")
	_clean()
	_test_missing()
	_test_layering()
	_test_env()
	_test_hardening()
	_test_bad_file()
	_test_server_tier()
	_test_legacy_shim()
	_clean()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _dir() -> String:
	return "user://cfg/addons/selftest_addon"


func _write(file: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(_dir())
	var f := FileAccess.open(_dir().path_join(file), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _server_dir() -> String:
	return "user://cfg/server/selftest_addon"


func _write_at(dir: String, file: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join(file), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	for dir in [_dir(), _server_dir(), "user://cfg/legacy_selftest"]:
		if DirAccess.dir_exists_absolute(dir):
			for f in DirAccess.get_files_at(dir):
				DirAccess.remove_absolute(dir.path_join(f))
			DirAccess.remove_absolute(dir)


func _test_missing() -> void:
	_section("A missing directory is not an error")
	var defaults := {"a": {"b": 1}, "name": "x"}
	var res := DotAddonConfig.load_dir(NAME, defaults)
	_check(res.ok, "load_dir succeeds with no directory")
	_check(DotAddonConfig.get_value(res.value, "a.b", 0) == 1, "defaults come back")
	_check(DotAddonConfig.get_value(res.value, "a.zzz", 7) == 7, "get_value falls back")
	_check(DotAddonConfig.dir_for(NAME) == _dir(), "dir_for names the user:// directory when none exists")
	_check(DotAddonConfig.describe(NAME).contains("0 file"), "describe reports no files")
	defaults["a"]["b"] = 99
	_check(DotAddonConfig.get_value(res.value, "a.b", 0) == 1, "the result is a copy")


func _test_layering() -> void:
	_section("Every yml is read, sorted by name, later overrides earlier")
	_write("20-late.yml", "a:\n  b: 3\nlist: [x, y]\n")
	_write("10-early.yml", "a:\n  b: 2\n  c: 5\nname: early\nlist: [1, 2, 3]\n")
	_write("notes.txt", "a:\n  b: 100\n")
	var res := DotAddonConfig.load_dir(NAME, {"a": {"d": 9}, "name": "x"})
	_check(res.ok, "two files load")
	_check(DotAddonConfig.get_value(res.value, "a.b") == 3, "the later file wins a shared key")
	_check(DotAddonConfig.get_value(res.value, "a.c") == 5, "maps merge key by key")
	_check(DotAddonConfig.get_value(res.value, "a.d") == 9, "a default survives under a file")
	_check(DotAddonConfig.get_value(res.value, "name") == "early", "a file overrides a default")
	_check((DotAddonConfig.get_value(res.value, "list") as Array).size() == 2, "a list is replaced whole")
	_check(DotAddonConfig.dir_for(NAME) == _dir(), "dir_for finds the directory")
	_check(DotAddonConfig.describe(NAME).contains("10-early.yml"), "describe names the files")


func _test_env() -> void:
	_section("Environment beats files; secrets are refused")
	_write("10.yml", "rotation:\n  mode: sequential\n  count: 3\n  on: false\napi_token: abc\n")
	OS.set_environment("SELFTEST_ADDON_ROTATION_MODE", "random")
	OS.set_environment("SELFTEST_ADDON_ROTATION_COUNT", "8")
	OS.set_environment("SELFTEST_ADDON_ROTATION_ON", "true")
	OS.set_environment("SELFTEST_ADDON_API_TOKEN", "stolen")
	var res := DotAddonConfig.load_dir(NAME)
	_check(DotAddonConfig.get_value(res.value, "rotation.mode") == "random", "a string from the environment")
	_check(DotAddonConfig.get_value(res.value, "rotation.count") == 8, "an int keeps its type")
	_check(DotAddonConfig.get_value(res.value, "rotation.on") == true, "a bool keeps its type")
	_check(DotAddonConfig.get_value(res.value, "api_token") == "abc", "a sensitive key is refused from the environment")
	_check(DotAddonConfig.describe(NAME).contains("refused"), "describe lists the refusal")
	OS.set_environment("SELFTEST_ADDON_ROTATION_COUNT", "many")
	res = DotAddonConfig.load_dir(NAME)
	_check(DotAddonConfig.get_value(res.value, "rotation.count") == 3, "a value of the wrong type is ignored")
	for k in ["MODE", "COUNT", "ON"]:
		OS.unset_environment("SELFTEST_ADDON_ROTATION_" + k)
	OS.unset_environment("SELFTEST_ADDON_API_TOKEN")


func _test_hardening() -> void:
	_section("Secret words, odd keys, coercion, CLI, ambiguity, names")
	_clean()
	_write("10.yml", "hotkey: a\nkeybind: b\nkey_repeat: 3\napi_key: k\nsecrets:\n  name: n\nauth:\n  token:\n    v: t\nplain: p\nnum: 2\nlist:\n  - 1\n  - 2\nemptymap:\nnest_a:\n  b: 1\n")
	var d := {"nothing": null, 7: "x", "has.dot": 1, "em": {}, "a_b": {"c": "one"}, "a": {"b_c": "two"}}
	var env := {"HOTKEY": "z", "KEYBIND": "z", "KEY_REPEAT": "9", "API_KEY": "z", "SECRETS_NAME": "z",
		"AUTH_TOKEN_V": "z", "NUM": "1e1", "LIST": "5,6,7", "NOTHING": "42", "A_B_C": "z"}
	for k in env:
		OS.set_environment("SELFTEST_ADDON_" + k, env[k])
	var res := DotAddonConfig.load_dir(NAME, d)
	var v: Dictionary = res.value
	_check(res.ok, "odd keys do not crash the load")
	_check(v["hotkey"] == "z" and v["keybind"] == "z", "hotkey and keybind are not secrets")
	_check(v["key_repeat"] == 9, "key_repeat is not a secret")
	_check(v["api_key"] == "k", "a *_key is refused")
	_check(v["secrets"]["name"] == "n", "a secret parent segment refuses its children")
	_check(v["auth"]["token"]["v"] == "t", "a token parent segment refuses its children")
	_check(v["num"] == 10, "an int accepts an integral float")
	_check(v["list"] == [5, 6, 7], "a list keeps the element type of its default")
	_check(v["nothing"] == 42, "a null default is overridable")
	_check(v["a_b"]["c"] == "one" and v["a"]["b_c"] == "two", "an ambiguous variable applies to neither")
	for k in env:
		OS.unset_environment("SELFTEST_ADDON_" + k)
	_check(DotAddonConfig._coerce("1.5", 3) == null, "a fractional float is not an int")
	_check(DotAddonConfig._coerce("true", null) == true, "null default parsed as a scalar")
	_check(DotAddonConfig._coerce("1,x", [1]) == null, "a bad list element fails the list")
	var leaves := PackedStringArray()
	DotAddonConfig._leaf_paths({"em": {}, 7: 1, "d.x": 2, "ok": 3}, "", leaves)
	_check(leaves == PackedStringArray(["ok"]), "empty maps, non-string and dotted keys are not leaves")
	_check(DotAddonConfig._is_sensitive("cfg.apiKey", PackedStringArray()), "camelCase apiKey is a secret")
	_check(not DotAddonConfig.load_dir("a\\b").ok and not DotAddonConfig.load_dir("c:d").ok, "backslash and colon are refused in names")
	_check(DotAddonConfig.write_dir_for(NAME).begins_with("user://cfg/"), "write_dir_for is under user://")
	_check(DotAddonConfig.export_filter_hint().contains("include_filter"), "export hint names include_filter")


func _test_bad_file() -> void:
	_section("A bad file is a DotResult error naming the file")
	_clean()
	_write("10-ok.yml", "a: 1\n")
	_write("20-bad.yml", "a:\n\tb: 1\n  - broken: [\n")
	var res := DotAddonConfig.load_dir(NAME)
	_check(not res.ok, "bad yml fails")
	_check(res.error.code == DotError.CODE_PARSE, "with CODE_PARSE")
	_check(res.error.message.contains("20-bad.yml"), "naming the file")
	_check(not DotAddonConfig.load_dir("../evil").ok, "a path in the addon name is refused")


func _test_server_tier() -> void:
	_section("Dashed names, the cfg/server operator tier over cfg/addons")
	_clean()
	_check(DotAddonConfig.folder_name("dot-map") == "dot_map", "a dashed addon name becomes underscored")
	_check(DotAddonConfig.folder_name("zombie_zone") == "zombie_zone", "an underscored name is unchanged")
	_check(DotAddonConfig.write_dir_for("dot-map") == "user://cfg/addons/dot_map", "write_dir_for underscores")
	_write("10-base.yml", "mode: addon\nkeep: 1\nnest:\n  a: 1\n  b: 2\n")
	_write_at(_server_dir(), "90-ops.yml", "mode: server\nnest:\n  b: 9\n")
	var res := DotAddonConfig.load_dir(NAME, {"mode": "default"})
	_check(res.ok, "addon and server files load together")
	_check(DotAddonConfig.get_value(res.value, "mode") == "server", "the server tier beats the addon tier")
	_check(DotAddonConfig.get_value(res.value, "keep") == 1, "an addon key the server tier leaves alone survives")
	_check(DotAddonConfig.get_value(res.value, "nest.a") == 1 and DotAddonConfig.get_value(res.value, "nest.b") == 9, "maps merge across tiers")
	var layers := DotAddonConfig.file_layers(NAME, "10-base.yml")
	_check(layers.size() == 1 and layers[0].ends_with("addons/selftest_addon/10-base.yml"), "file_layers finds the addon copy only when the server has none")
	_write_at(_server_dir(), "10-base.yml", "mode: s\n")
	layers = DotAddonConfig.file_layers(NAME, "10-base.yml")
	_check(layers.size() == 2 and layers[1].contains("/server/"), "file_layers lists the server copy last (strongest)")
	_check(DotAddonConfig.file_layers(NAME, "missing.yml").is_empty(), "file_layers of a missing file is empty")
	_write_at(_server_dir(), "10-base.yml", "a:\n\tb: 1\n  - broken: [\n")
	res = DotAddonConfig.load_dir(NAME)
	_check(not res.ok and res.error.code == DotError.CODE_PARSE, "a bad server-tier file fails with CODE_PARSE")
	_clean()
	_write_at(_server_dir(), "only.yml", "x: 1\n")
	_check(DotAddonConfig.get_value(DotAddonConfig.load_dir(NAME).value, "x") == 1, "a server-tier file alone is read")
	_check(DotAddonConfig.dir_for(NAME) == _dir(), "dir_for stays on the addon tier")


func _test_legacy_shim() -> void:
	_section("DotCfgLegacy: new wins, old warns once, expiry")
	_clean()
	DotCfgLegacy.reset()
	var dir := "user://cfg/legacy_selftest"
	var old_p := dir.path_join("maps.yml")
	var new_p := dir.path_join("new.yml")
	_check(DotCfgLegacy.find(old_p, new_p) == "" and DotCfgLegacy.warned_count() == 0, "neither file: nothing, no warning")
	_write_at(dir, "maps.yml", "a: 1\n")
	_check(DotCfgLegacy.find(old_p, new_p) == old_p, "only the old file: it is still read")
	_check(DotCfgLegacy.warned_count() == 1, "and warned")
	DotCfgLegacy.find(old_p, new_p)
	DotCfgLegacy.find(old_p, new_p)
	_check(DotCfgLegacy.warned_count() == 1, "the warning is once per old path")
	_write_at(dir, "new.yml", "a: 2\n")
	_check(DotCfgLegacy.find(old_p, new_p) == new_p, "both files: the new one wins whole")
	DotCfgLegacy.reset()
	DotCfgLegacy.today_override = "2027-01-01"
	DirAccess.remove_absolute(new_p)
	_check(DotCfgLegacy.find(old_p, new_p) == "", "after the removal date the old path is ignored")
	_check(DotCfgLegacy.warned_count() == 1, "and reported once as an error")
	_check(DotCfgLegacy.REMOVE_AFTER == "2026-12-31", "the removal date is 2026-12-31")
	DotCfgLegacy.reset()


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
