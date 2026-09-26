extends Node

## Exercises [DotAddonApi]: what a build has, what a pack needs, and the sentence between.
##
## [codeblock]
## godot --headless --path . res://examples/addon_api_selftest.tscn
## [/codeblock]
##
## [b]The sentences are asserted, not only the codes.[/b] The whole point of the class is
## that a player reads "this server has level 2" instead of a parse error, so a check that
## the refusal is CODE_VERSION and nothing else would pass for a refusal nobody can read.

const SECTIONS := 6
const CHECKS := 36

const SCRATCH := "user://addon_api_selftest"

var _passed := 0
var _failed := 0
var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("dot-core addon API self-test")

	_test_what_this_build_has()
	_test_reading_a_requirements_file()
	_test_a_requirement_this_build_meets()
	_test_the_refusals_read_as_sentences()
	_test_a_mounted_pack()
	_test_deriving_and_auditing()

	print("")
	print("%d of %d sections finished, %d passed, %d failed" % [_finished, _entered, _passed, _failed])

	if _entered != SECTIONS or _finished != SECTIONS:
		print("ERROR: %d sections entered and %d finished, %d expected." % [_entered, _finished, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _test_what_this_build_has() -> void:
	_section("what this build has")

	var api := DotAddonApi.new()

	_check(DotAddonApi.installed("dot_core"), "dot-core is installed")
	_check(not DotAddonApi.installed("dot_no_such_addon"), "an addon that is not here is not installed")
	_check(not DotAddonApi.installed("../dot_core"), "and a name that walks out of addons/ is not an addon")
	_check(api.level_of("dot_core") == 1, "dot-core's level is read from its api file (%d)" % api.level_of("dot_core"))
	_check(api.level_of("dot_no_such_addon") == 0, "an absent addon has level 0")
	_check(DotAddonApi.display_name("dot_player_controller") == "dot-player-controller", "and it is named the way a person names it")

	api.overrides["dot_core"] = 7
	_check(api.level_of("dot_core") == 7, "an override stands in for the build")
	_check(api.oldest_of("dot_core") == 1, "and keeps the build's oldest when it names none")
	api.overrides["dot_core"] = {"level": 7, "oldest": 5}
	_check(api.oldest_of("dot_core") == 5, "or takes the one it names")

	_done()


func _test_reading_a_requirements_file() -> void:
	_section("reading a requirements file")

	var good := DotAddonApi.parse('{"format": 1, "addons": {"dot_net": 3, "dot_core": 1}}')
	_check(good.ok and (good.value as Dictionary).get("dot_net") == 3, "a good file reads (%s)" % str(good.value if good.ok else good.error))

	_check(DotAddonApi.parse("not json").code() == DotError.CODE_PARSE, "not JSON is a parse failure")
	_check(DotAddonApi.parse('{"addons": {"dot_net": 0}}').code() == DotError.CODE_PARSE, "a level of 0 is refused, not treated as none")
	_check(DotAddonApi.parse('{"addons": {"dot_net": 1.5}}').code() == DotError.CODE_PARSE, "a fractional level is refused")
	_check(DotAddonApi.parse('{"addons": {"dot_net": "3"}}').code() == DotError.CODE_PARSE, "a level written as text is refused")
	_check(DotAddonApi.parse('{"addons": {"../evil": 1}}').code() == DotError.CODE_PARSE, "an addon name that cannot exist is refused")
	_check(DotAddonApi.parse('{"format": 99, "addons": {}}').code() == DotError.CODE_VERSION, "a newer format says it is newer")

	# Two builds of one tree must write the same bytes, or a release that re-derives the
	# file reports a change that is not one.
	var a := DotAddonApi.encode({"dot_net": 2, "dot_core": 1})
	var b := DotAddonApi.encode({"dot_core": 1, "dot_net": 2})
	_check(a == b, "encoding is sorted, so the order a table was built in does not show")
	var back := DotAddonApi.parse(a)
	_check(back.ok and (back.value as Dictionary).size() == 2, "and what it writes reads back")

	_done()


func _test_a_requirement_this_build_meets() -> void:
	_section("a requirement this build meets")

	var api := DotAddonApi.new()
	_check(api.check({"dot_core": 1}, "server").ok, "needing what this build has is fine")
	_check(api.check({}, "server").ok, "needing nothing is fine")

	api.overrides["dot_core"] = 4
	_check(api.check({"dot_core": 3}, "server").ok, "and so is needing less than this build has")

	_done()


func _test_the_refusals_read_as_sentences() -> void:
	_section("each refusal is a sentence a player can read")

	var api := DotAddonApi.new()
	api.overrides["dot_core"] = 2

	var newer := api.check({"dot_core": 3}, "server")
	_check(not newer.ok and newer.code() == DotError.CODE_VERSION, "a pack needing more is CODE_VERSION")
	_check(
		not newer.ok and newer.error.message == "This game needs dot-core API level 3 or newer; this server has level 2.",
		"and says so", newer.error.message if not newer.ok else ""
	)

	var missing := api.check({"dot_no_such_addon": 1}, "client")
	_check(
		not missing.ok and missing.error.message == "This game needs dot-no-such-addon, and this client does not have it.",
		"an addon that is not here is named", missing.error.message if not missing.ok else ""
	)

	api.overrides["dot_core"] = {"level": 6, "oldest": 4}
	var older := api.check({"dot_core": 2}, "server")
	_check(
		not older.ok and older.error.message.contains("no longer supports (it supports 4 to 6)"),
		"a pack built for a level this build dropped says which ones it takes", older.error.message if not older.ok else ""
	)

	api.overrides["dot_core"] = 2
	var both := api.check({"dot_no_such_addon": 1, "dot_core": 9}, "server")
	_check(not both.ok and both.error.detail.contains("dot_core>=9") and both.error.detail.contains("dot_no_such_addon>=1"),
		"every unmet requirement is in the detail", both.error.detail if not both.ok else "")
	_check(not both.ok and both.error.message.contains("dot-core"), "and the message is the first of them, in name order")

	var text := api.check_text("{", "server")
	_check(text.code() == DotError.CODE_PARSE, "a file that does not parse is refused as one rather than as met")

	_done()


func _test_a_mounted_pack() -> void:
	_section("a pack's own file, where it would be mounted")

	DirAccess.make_dir_recursive_absolute(SCRATCH)
	var none_dir := SCRATCH + "/none"
	DirAccess.make_dir_recursive_absolute(none_dir)
	var file_path := SCRATCH + "/" + DotAddonApi.REQUIREMENTS_FILE
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(file_path)

	var api := DotAddonApi.new()
	_check(api.check_mounted(none_dir, "client").ok, "a pack with no file needs nothing that can be checked")

	var f := FileAccess.open(file_path, FileAccess.WRITE)
	f.store_string(DotAddonApi.encode({"dot_core": 2}))
	f.close()

	var refused := api.check_mounted(SCRATCH, "client")
	_check(not refused.ok and refused.error.message.contains("this client has level 1"), "one asking for more than this build has is refused", str(refused.error) if not refused.ok else "")

	api.overrides["dot_core"] = 2
	_check(api.check_mounted(SCRATCH + "/", "client").ok, "and passes on a build that has it, trailing slash or not")

	DirAccess.remove_absolute(file_path)
	DirAccess.remove_absolute(none_dir)
	DirAccess.remove_absolute(SCRATCH)

	_done()


func _test_deriving_and_auditing() -> void:
	_section("what a game uses, and whether its own file says so")

	# dot-core's own project has nothing outside addons/ and examples/, so there is
	# nothing of an addon's in use; the consumers' suites are where derive meets a game.
	var derived := DotAddonApi.derive()
	_check(derived.is_empty(), "this project, with its examples skipped, uses no addon (%s)" % str(derived))

	var with_examples := DotAddonApi.derive("res://", PackedStringArray(["addons", ".godot"]))
	_check(with_examples.get("dot_core") == 1, "with them, it uses dot-core at this build's level (%s)" % str(with_examples))

	var missing := DotAddonApi.audit({}, {"dot_net": 2})
	_check(missing.size() == 1 and missing[0].contains("not declared"), "an addon used and not declared is reported")
	var over := DotAddonApi.audit({"dot_net": 5}, {"dot_net": 2})
	_check(over.size() == 1 and over[0].contains("declared at 5"), "and so is a level above what this build has")
	_check(DotAddonApi.audit({"dot_net": 1}, {"dot_net": 2}).is_empty(), "a lower level is a game that knows better, and is fine")

	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  -- " + detail])
