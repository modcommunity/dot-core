@tool
class_name DotValue
extends RefCounted

## Comparisons that are total, because GDScript's are not: `==` between mismatched Variant
## types is a runtime ERROR, not false, and the caller carries on with a plausible wrong answer.
## Use these wherever a side is a [Variant] whose type you do not control (config, wire, sentinel);
## ordinary comparisons of declared types should stay as they are.

## Whether two values are the same value, without erroring on mismatched types. Different
## types differ, except [int] against [float] and [StringName] against [String], which fold:
## a JSON round trip changes the type and a "nothing changed" check must not fire.
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


## Whether [param value] is null, or an empty string, array or dictionary; [code]value == ""[/code]
## on an Array is the same runtime error.
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


## Whether every key of [param a] has the same value in [param b], and vice versa, using
## [method same] per key so a JSON round trip compares equal.
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
