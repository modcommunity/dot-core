extends Node

## Exercises the Gamespice spelling of environment variables: for any [code]DOT_X[/code] the engine reads,
## [code]GS_X[/code] is read first and the old name keeps working ([method DotConfig.gs_env_name]).

const SECTIONS := 3
const CHECKS := 12
const ADDON := "dot_gs_env_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	_line("dot-core env rename self-test")
	_test_names()
	_test_config()
	_test_addon_config()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections and %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_names() -> void:
	_section("GS_X is read first, DOT_X still works")
	_unset(["DOT_GS_SELFTEST_A", "GS_GS_SELFTEST_A"])
	_check(DotConfig.gs_env_name("DOT_GS_SELFTEST_A") == "DOT_GS_SELFTEST_A", "with neither set the old name is kept")
	OS.set_environment("DOT_GS_SELFTEST_A", "old")
	_check(DotConfig.gs_env("DOT_GS_SELFTEST_A") == "old", "the old name alone is read")
	OS.set_environment("GS_GS_SELFTEST_A", "new")
	_check(DotConfig.gs_env_name("DOT_GS_SELFTEST_A") == "GS_GS_SELFTEST_A", "the GS name is chosen when set")
	_check(DotConfig.gs_env("DOT_GS_SELFTEST_A") == "new", "and its value wins over the old one")
	OS.set_environment("SELFTEST_PLAIN", "p")
	_check(DotConfig.gs_env_name("SELFTEST_PLAIN") == "SELFTEST_PLAIN" and DotConfig.gs_env("SELFTEST_PLAIN") == "p", "a name without DOT_ is untouched")
	_unset(["DOT_GS_SELFTEST_A", "GS_GS_SELFTEST_A", "SELFTEST_PLAIN"])


func _test_config() -> void:
	_section("DotConfig.apply_env takes either spelling")
	_unset(["DOT_RANDOM_MASTER_SEED", "GS_RANDOM_MASTER_SEED"])
	var cfg := DotRandomConfig.new()
	OS.set_environment("DOT_RANDOM_MASTER_SEED", "5")
	cfg.apply_env()
	_check(cfg.master_seed == 5, "DOT_RANDOM_MASTER_SEED still applies")
	OS.set_environment("GS_RANDOM_MASTER_SEED", "9")
	cfg.apply_env()
	_check(cfg.master_seed == 9, "GS_RANDOM_MASTER_SEED wins when both are set")
	OS.unset_environment("DOT_RANDOM_MASTER_SEED")
	cfg = DotRandomConfig.new()
	cfg.apply_env()
	_check(cfg.master_seed == 9, "GS_RANDOM_MASTER_SEED alone applies")
	_unset(["DOT_RANDOM_MASTER_SEED", "GS_RANDOM_MASTER_SEED"])


func _test_addon_config() -> void:
	_section("DotAddonConfig reads GS_ for a dot_ addon")
	var dot_key := "DOT_GS_ENV_SELFTEST_SPEED"
	var gs_key := "GS_GS_ENV_SELFTEST_SPEED"
	_unset([dot_key, gs_key])
	var res := DotAddonConfig.load_dir(ADDON, {"speed": 1})
	_check(res.ok and (res.value as Dictionary)["speed"] == 1, "with neither set the default stands")
	OS.set_environment(dot_key, "2")
	res = DotAddonConfig.load_dir(ADDON, {"speed": 1})
	_check(res.ok and (res.value as Dictionary)["speed"] == 2, "the old DOT_ variable applies")
	OS.set_environment(gs_key, "3")
	res = DotAddonConfig.load_dir(ADDON, {"speed": 1})
	_check(res.ok and (res.value as Dictionary)["speed"] == 3, "the GS_ variable wins")
	OS.unset_environment(dot_key)
	res = DotAddonConfig.load_dir(ADDON, {"speed": 1})
	_check(res.ok and (res.value as Dictionary)["speed"] == 3, "the GS_ variable alone applies")
	_unset([dot_key, gs_key])


func _unset(names: Array) -> void:
	for n: String in names:
		OS.unset_environment(n)


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("--- %s ---" % title)


func _check(passed: bool, what: String) -> void:
	if passed:
		_passed += 1
		_line("  ok   " + what)
	else:
		_failed += 1
		_line("  FAIL " + what)


func _line(text: String) -> void:
	print(text)
