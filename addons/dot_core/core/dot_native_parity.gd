class_name DotNativeParity
extends RefCounted

## Holds a native (GDExtension) twin to its script original: the same inputs through both, answers compared to the bit.
## Nothing here needs a native library. With the class absent (web, an unsupported platform, no library installed) a
## comparison is [constant SKIPPED] and the caller keeps its script path, which is the behaviour the game ships there.
## Set the environment variable [constant ENV_REQUIRED] to 1 on a machine that must have the library: a skip then fails.
##
## [codeblock]
## var p := DotNativeParity.new("crc")
## var r := p.compare(&"DotSimCrc", inputs, DotMapVpk.crc32_script, func(x): return DotSimCrc.new().crc32(x))
## # r.status is PASS, FAIL or SKIPPED; r.first (the first differing case) is "" unless FAIL.
## [/codeblock]

const PASS := &"pass"
const FAIL := &"fail"
const SKIPPED := &"skipped"

## Environment variable: 1 makes an absent native class a failure instead of a skip.
const ENV_REQUIRED := "GS_NATIVE_REQUIRED"

## Label printed with results.
var name: String = ""

## Cases compared, cases that differed, and compares skipped, over this object's life.
var compared: int = 0
var differed: int = 0
var skipped: int = 0


func _init(p_name: String = "") -> void:
	name = p_name


## Whether native class [param native_class] is loaded. Reached by name, never as a typed class, so scripts compile
## without the library. False on every web export made with the plain template.
static func available(native_class: StringName) -> bool:
	return ClassDB.class_exists(native_class)


## Whether this machine must have the native library ([constant ENV_REQUIRED]=1).
static func required() -> bool:
	return OS.get_environment(ENV_REQUIRED) == "1"


## Equality to the bit: the same type and the same bytes, so -0.0 is not 0.0 and a NaN equals the same NaN. Objects
## cannot be serialised without their scripts, so they compare by identity.
static func same(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Object or b is Object:
		return a == b
	if a is Array or a is Dictionary:
		return _same_deep(a, b)
	if a is float:
		# var_to_bytes may fold -0.0 and 0.0; the raw 64 bits cannot.
		return PackedFloat64Array([a]).to_byte_array() == PackedFloat64Array([b]).to_byte_array()
	return var_to_bytes(a) == var_to_bytes(b)


static func _same_deep(a: Variant, b: Variant) -> bool:
	if a is Array:
		var xa: Array = a
		var xb: Array = b
		if xa.size() != xb.size():
			return false
		for i in xa.size():
			if not same(xa[i], xb[i]):
				return false
		return true
	var da: Dictionary = a
	var db: Dictionary = b
	if da.size() != db.size():
		return false
	for k: Variant in da:
		if not db.has(k) or not same(da[k], db[k]):
			return false
	return true


## Runs every element of [param inputs] through [param script_fn] and [param native_fn] (each takes one input and
## returns the answer) and compares. To pass several arguments, make each input an Array and unpack it in the Callable.
## Returns {status, cases, differing, first, native_present}. [param native_class] is the class the native path
## needs; absent, nothing runs and the status is [constant SKIPPED] (or [constant FAIL] when [method required]).
func compare(native_class: StringName, inputs: Array, script_fn: Callable, native_fn: Callable) -> Dictionary:
	var out := {"status": PASS, "cases": 0, "differing": 0, "first": "", "native_present": available(native_class)}
	if not out["native_present"]:
		skipped += 1
		out["status"] = FAIL if required() else SKIPPED
		out["first"] = "native class %s absent" % native_class
		return out
	for i in inputs.size():
		var s: Variant = script_fn.call(inputs[i])
		var n: Variant = native_fn.call(inputs[i])
		out["cases"] += 1
		compared += 1
		if not same(s, n):
			differed += 1
			out["differing"] += 1
			if out["first"] == "":
				out["first"] = "case %d: input %s script %s native %s" % [i, str(inputs[i]), str(s), str(n)]
	if out["differing"] > 0:
		out["status"] = FAIL
	return out


## Microseconds per call of [param fn] over [param inputs], [param reps] passes after one warm-up pass.
## For before/after numbers in a commit message; not a gate.
static func bench(fn: Callable, inputs: Array, reps: int = 5) -> float:
	if inputs.is_empty() or reps < 1:
		return 0.0
	for x: Variant in inputs:
		fn.call(x)
	var t0 := Time.get_ticks_usec()
	for _r in reps:
		for x: Variant in inputs:
			fn.call(x)
	return float(Time.get_ticks_usec() - t0) / float(reps * inputs.size())


func describe() -> Dictionary:
	return {"name": name, "compared": compared, "differed": differed, "skipped": skipped}
