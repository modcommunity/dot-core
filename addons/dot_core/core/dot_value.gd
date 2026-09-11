@tool
class_name DotValue
extends RefCounted

## Comparisons that are total, because GDScript's are not.
##
## [b]`==` and `!=` between two mismatched Variant types are a runtime ERROR, not
## [code]false[/code] and [code]true[/code].[/b] The expression is abandoned, an error is
## pushed, and the calling function carries on with whatever the abandoned expression
## evaluated to — so the caller sees a plausible answer and the only trace is a line in a
## log nobody is reading.
##
## [codeblock]
## var a: Variant = 110        # an int a coercion produced
## var b: Variant = "110"      # the String it came from
## if a != b:                  # Invalid operands 'int' and 'String' in operator '!='
##     ...                     # and this branch's condition is now undefined
## [/codeblock]
##
## This family has been bitten by it twice in two different addons.
## [code]DotNpcAiBlackboard.has()[/code] was the textbook sentinel comparison —
## [code]get_value(key, now, MISSING) != MISSING[/code] — and answered false for every
## value that was not a [StringName], because comparing a [Vector3] with one is an error
## rather than a difference. dot-settings then hit the same thing comparing a coerced
## value with the raw one it was coerced from.
##
## The shape is always the same: a comparison where one side's type is under the caller's
## control and the other's is not. A configuration file, a wire message, a saved document,
## a sentinel — anything that arrives as [Variant].
##
## [b]Use these anywhere either side is a [Variant] whose type you do not control.[/b]
## Ordinary comparisons between two values of a declared type are fine and should stay as
## they are; wrapping those in a call would be noise.

## Whether two values are the same value, without erroring on mismatched types.
##
## Different types are simply different, which is what the comparison was asking anyway.
## The one deliberate exception is [int] against [float]: GDScript compares those happily
## and every caller means them to be equal when they are numerically equal, so
## [code]same(1, 1.0)[/code] is true.
##
## [StringName] against [String] is also folded, for the same reason: a value that made a
## round trip through JSON comes back as a [String] and a value read from a declaration is
## a [StringName], they print identically, and treating them as different is how a
## "nothing changed" check reports a change on every load.
static func same(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if ta == tb:
		return a == b

	if _is_number(ta) and _is_number(tb):
		# bool is a number here on purpose: it is what `== 0` does everywhere else in
		# GDScript, and a config value stored as 1 and re-read as true is the same value.
		return float(a) == float(b)

	if _is_text(ta) and _is_text(tb):
		return String(a) == String(b)

	if ta == TYPE_NIL or tb == TYPE_NIL:
		return false

	return false


## The negation, spelled out because that is how the comparison is usually written.
static func differs(a: Variant, b: Variant) -> bool:
	return not same(a, b)


## Whether [param value] is null, or an empty string, array or dictionary.
##
## Not a comparison, but the same trap one step along: [code]value == ""[/code] on
## something that might be an [Array] is the identical runtime error.
static func is_blank(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL:
			return true
		TYPE_STRING, TYPE_STRING_NAME:
			return String(value).is_empty()
		TYPE_ARRAY:
			return (value as Array).is_empty()
		TYPE_DICTIONARY:
			return (value as Dictionary).is_empty()
		_:
			return false


## Whether every key of [param a] has the same value in [param b], and vice versa.
##
## Uses [method same] per key, so a document that made a round trip through JSON compares
## equal to the one it was written from. A plain [code]a == b[/code] on two dictionaries
## is exact about types and will say two identical documents differ.
static func same_dictionary(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a.keys():
		if not b.has(k):
			return false
		if differs(a[k], b[k]):
			return false
	return true


## The negation of [method same_dictionary].
static func differs_dictionary(a: Dictionary, b: Dictionary) -> bool:
	return not same_dictionary(a, b)


static func _is_number(t: int) -> bool:
	return t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_BOOL


static func _is_text(t: int) -> bool:
	return t == TYPE_STRING or t == TYPE_STRING_NAME
