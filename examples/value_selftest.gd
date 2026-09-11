extends Node

## Exercises [DotValue], the comparisons that are total.
##
## [b]Every check here would be a runtime ERROR written the obvious way.[/b] That is the
## point of the class and it is why the checks look trivial: `1 != "1"` is not `true` in
## GDScript, it is an abandoned expression and a line in a log.
##
## [codeblock]
## godot --headless --path . res://examples/value_selftest.tscn
## [/codeblock]

const SECTIONS := 4
const CHECKS := 27

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-core value self-test")
	_line("")

	_test_mismatched_types()
	_test_number_and_text_folding()
	_test_blank()
	_test_dictionaries()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _test_mismatched_types() -> void:
	_section("Two different types are different, not an error")

	# Every one of these, written as `a != b`, pushes "Invalid operands" and abandons the
	# expression. DotNpcAiBlackboard.has() was exactly this and answered false for every
	# value that was not a StringName.
	_check(DotValue.differs(Vector3.ZERO, &"missing"), "a Vector3 is not a StringName")
	_check(DotValue.differs(110, [110]), "a number is not an array holding it")
	_check(DotValue.differs({}, []), "an empty dictionary is not an empty array")
	_check(DotValue.differs(null, 0), "null is not zero")
	_check(DotValue.differs(null, ""), "null is not the empty string")
	_check(DotValue.same(null, null), "and null is null")

	_check(DotValue.same(Vector3(1, 2, 3), Vector3(1, 2, 3)), "two equal vectors are equal")
	_check(DotValue.differs(Vector3(1, 2, 3), Vector3(1, 2, 4)), "and two unequal ones are not")


func _test_number_and_text_folding() -> void:
	_section("The two foldings, which are deliberate")

	# int against float is folded because GDScript compares them happily and every caller
	# means them to be equal. A config value stored as 1 and re-read as 1.0 is one value.
	_check(DotValue.same(1, 1.0), "an int equals the float beside it")
	_check(DotValue.same(true, 1), "and a bool equals the number it is")
	_check(DotValue.differs(1, 2.0), "while two different numbers still differ")

	# StringName against String is folded because a value that made a round trip through
	# JSON comes back as one and a value read from a declaration is the other. They print
	# identically, and calling them different reports a change on every single load.
	_check(DotValue.same(&"high", "high"), "a StringName equals the String that prints the same")
	_check(DotValue.differs(&"high", "low"), "and two different names still differ")

	# The one that is NOT folded, and the reason the schema compares printed forms where
	# it means "did this change for a person".
	_check(DotValue.differs(110, "110"), "a number is not the text of that number")


func _test_blank() -> void:
	_section("Blank, which is the same trap one step along")

	_check(DotValue.is_blank(null), "null is blank")
	_check(DotValue.is_blank(""), "the empty string is blank")
	_check(DotValue.is_blank(&""), "and so is the empty StringName")
	_check(DotValue.is_blank([]), "an empty array is blank")
	_check(DotValue.is_blank({}), "an empty dictionary is blank")
	_check(not DotValue.is_blank(0), "zero is not blank, because zero is a value")
	_check(not DotValue.is_blank(false), "and neither is false")
	_check(not DotValue.is_blank("x"), "nor is anything with something in it")


func _test_dictionaries() -> void:
	_section("Documents that made a round trip")

	var written := {"fov": 90, "quality": &"high", "volume": 1}
	var read_back := {"fov": 90.0, "quality": "high", "volume": true}
	_check(
		DotValue.same_dictionary(written, read_back),
		"a document round-tripped through JSON compares equal to the one it was written from"
	)
	_check(
		written != read_back,
		"which a plain == on the two dictionaries does not say"
	)
	_check(
		DotValue.differs_dictionary(written, {"fov": 91, "quality": "high", "volume": 1}),
		"while a document with a different value in it does differ"
	)
	_check(
		DotValue.differs_dictionary(written, {"fov": 90}),
		"and so does one that is missing a key"
	)
	_check(
		DotValue.differs_dictionary({"fov": 90}, written),
		"in either direction"
	)


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
