extends Node

## Exercises [DotAddonConfig]: `cfg/addons/<name>/*.yml` read in file-name order over defaults.
##
## [codeblock]
## godot --headless --path . res://examples/addon_config_selftest.tscn
## [/codeblock]

const SECTIONS := 4
const CHECKS := 24
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
	_test_bad_file()
	_clean()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _dir() -> String:
	return "user://cfg/addons/" + NAME


func _write(file: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(_dir())
	var f := FileAccess.open(_dir().path_join(file), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	if DirAccess.dir_exists_absolute(_dir()):
		for f in DirAccess.get_files_at(_dir()):
			DirAccess.remove_absolute(_dir().path_join(f))
		DirAccess.remove_absolute(_dir())


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
