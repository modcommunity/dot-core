extends Node

## Exercises [DotNativeParity] with a stand-in "native" path (a Callable): equal answers pass, a one-bit float
## difference fails, -0.0 and NaN compare as bits, an absent class skips, GS_NATIVE_REQUIRED turns the skip into a failure.

const CHECKS := 12

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("dot-core native parity self-test")
	var zero := 0.0
	var xs: Array = [1.0, 2.5, -3.0, 0.1]
	var dbl := func(x: float) -> float: return x * 2.0
	var p := DotNativeParity.new("t")
	# RefCounted is a class that always exists: it stands in for "the native class is loaded".
	var r := p.compare(&"RefCounted", xs, dbl, dbl)
	_check(r["status"] == DotNativeParity.PASS and r["cases"] == 4, "equal paths pass")
	var off := func(x: float) -> float: return x * 2.0 + (1e-12 if x == 0.1 else 0.0)
	r = p.compare(&"RefCounted", xs, dbl, off)
	_check(r["status"] == DotNativeParity.FAIL and r["differing"] == 1, "a one-bit difference fails once")
	_check(String(r["first"]).begins_with("case 3"), "first difference names the case")
	_check(not DotNativeParity.same(zero, -zero), "-0.0 is not 0.0")
	_check(DotNativeParity.same(NAN, NAN), "NaN equals the same NaN")
	_check(not DotNativeParity.same(1, 1.0), "int is not float")
	_check(DotNativeParity.same({"a": [1, 2.0, Vector3(1, 2, 3)]}, {"a": [1, 2.0, Vector3(1, 2, 3)]}), "nested equal")
	_check(not DotNativeParity.same(PackedFloat32Array([1.0]), PackedFloat32Array([1.0, 2.0])), "packed length differs")
	r = p.compare(&"NoSuchNativeClassXyz", xs, dbl, dbl)
	_check(r["status"] == DotNativeParity.SKIPPED and not r["native_present"], "absent class skips")
	_check(p.skipped == 1 and p.differed == 1, "counters")
	var us := DotNativeParity.bench(dbl, xs, 2)
	_check(us >= 0.0, "bench returns a time")
	_check(DotNativeParity.required() == (OS.get_environment("GS_NATIVE_REQUIRED") == "1"), "required reads the environment")
	print("%d passed, %d failed" % [_passed, _failed])
	if _passed + _failed != CHECKS:
		print("ERROR: %d of %d checks ran." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL: " + what)
