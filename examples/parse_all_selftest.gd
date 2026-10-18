extends Node

## Runs tools/dot_parse_all.gd, as a separate process, over scripts known to be bad and good.
##
## [b]The bad scripts are written to user:// here, not committed.[/b] A tracked broken
## .gd would fail this repository's own parse pass and dot-ci on every push, which is the
## pass the tool exists to speed up. Armed by construction: every bad one must be named,
## the good ones must not be, and the process must exit non-zero.
##
## [codeblock]
## godot --headless --path . res://examples/parse_all_selftest.tscn
## [/codeblock]

const TOOL := "res://addons/dot_core/tools/dot_parse_all.gd"
const DIR := "user://parse_all_selftest"
const FILES := {
	"good.gd": "class_name DotParseGood\nextends RefCounted\nfunc hi() -> int:\n\treturn 1\n",
	"bad_syntax.gd": "extends Node\nfunc f(\n\tpass\n",
	"bad_type.gd": "extends Node\nfunc f() -> void:\n\tvar x: int = \"s\"\n",
	"bad_ident.gd": "extends Node\nfunc f() -> void:\n\tUndeclaredThing.go()\n",
	"dep_on_bad.gd": "extends Node\nconst B = preload(\"user://parse_all_selftest/bad_syntax.gd\")\n",
	"ok_plain.gd": "extends Node\nfunc f() -> int:\n\treturn 2\n",
}
const BAD := ["bad_syntax.gd", "bad_type.gd", "bad_ident.gd", "dep_on_bad.gd"]
const GOOD := ["good.gd", "ok_plain.gd"]

var _passed := 0
var _failed := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var list := PackedStringArray()
	for f in FILES:
		var w := FileAccess.open("%s/%s" % [DIR, f], FileAccess.WRITE)
		w.store_string(FILES[f])
		w.close()
		list.append("%s/%s" % [DIR, f])
	var lf := FileAccess.open(DIR + "/list.txt", FileAccess.WRITE)
	lf.store_string("\n".join(list) + "\n")
	lf.close()

	print("dot-core parse_all self-test")
	var out := []
	var code := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", TOOL, "--", ProjectSettings.globalize_path(DIR + "/list.txt")], out, true)
	var text := str(out[0]) if not out.is_empty() else ""
	_check(code == 1, "exits 1 when scripts are bad (got %d)" % code)
	_check(text.contains("PARSED 6 FAILED"), "reports the total")
	_check(text.contains("PARSE_END"), "ends with PARSE_END")
	for f in BAD:
		_check(text.contains("PARSE_FAIL %s/%s" % [DIR, f]), "names %s" % f)
	for f in GOOD:
		_check(not text.contains("PARSE_FAIL %s/%s" % [DIR, f]), "does not name %s" % f)
		_check(text.contains("PARSE> %s/%s" % [DIR, f]), "marks %s before loading" % f)

	# A good list alone exits 0 with nothing failed.
	var lg := FileAccess.open(DIR + "/good_list.txt", FileAccess.WRITE)
	lg.store_string("%s/good.gd\n%s/ok_plain.gd\n" % [DIR, DIR])
	lg.close()
	var out2 := []
	var code2 := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", TOOL, "--", ProjectSettings.globalize_path(DIR + "/good_list.txt")], out2, true)
	_check(code2 == 0, "exits 0 on a clean list (got %d)" % code2)
	_check(str(out2[0]).contains("PARSED 2 FAILED 0"), "clean list: PARSED 2 FAILED 0")

	print("%d passed, %d failed" % [_passed, _failed])
	if _failed > 0:
		print(text)
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL ", what)
