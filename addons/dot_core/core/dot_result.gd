class_name DotResult
extends RefCounted

## The return type of every fallible operation in the dot-* family.
##
## GDScript has no tagged unions and no exceptions, so the alternatives are
## returning [code]null[/code] on failure (which loses the reason) or an
## [code]Array[/code] pair (which loses type checking at every call site). This
## costs one allocation and buys a failure that cannot be silently ignored:
## reading [member value] on a failed result pushes an error rather than
## handing back a plausible-looking default.
##
## [codeblock]
## var res := await store.read("objects/ab/abcd")
## if not res.ok:
##     DotLog.warn("store", "read failed: %s" % res.error)
##     return
## var bytes: PackedByteArray = res.value
## [/codeblock]

var ok: bool = false
var error: DotError = null

var _value: Variant = null


static func success(p_value: Variant = null) -> DotResult:
	var r := DotResult.new()
	r.ok = true
	r._value = p_value
	return r


static func failure(p_error: DotError) -> DotResult:
	var r := DotResult.new()
	r.ok = false
	r.error = p_error
	return r


## Shorthand for [code]failure(DotError.make(code, message, detail))[/code].
static func fail(
	code: String,
	message: String,
	detail: String = ""
) -> DotResult:
	return DotResult.failure(DotError.make(code, message, detail))


## The success payload.
##
## Reading this on a failed result is a programming error: it means a caller
## skipped the [member ok] check, and returning a bare [code]null[/code] would
## let that mistake travel. We complain loudly and still return null so the
## crash, if any, happens at the real call site.
var value: Variant:
	get:
		if not ok:
			push_error(
				"DotResult.value read on a failed result: %s"
				% (str(error) if error != null else "<no error>")
			)
		return _value
	set(_v):
		push_error("DotResult.value is read-only; build a new result instead.")


## The payload, or [param default] when this result failed.
##
## Use when a failure genuinely has a sensible fallback — a cached value, an
## empty list — and you do not want the branch.
func value_or(default: Variant) -> Variant:
	return _value if ok else default


## The failure code, or [code]""[/code] on success. Safe to call either way.
func code() -> String:
	return "" if ok or error == null else error.code


func is_retryable() -> bool:
	return (not ok) and error != null and error.is_retryable()


## Re-wraps a failure with a new message while keeping the original as detail.
##
## Lets a layer add context ("could not mount game 'dm_arena'") without
## discarding the cause ("integrity: chunk 4 hash mismatch").
func wrap(message: String) -> DotResult:
	if ok:
		return self

	var e := DotError.make(
		error.code if error != null else DotError.CODE_INTERNAL,
		message,
		str(error) if error != null else ""
	)
	if error != null:
		e.retry_after = error.retry_after
		e.http_status = error.http_status
		e.context = error.context
	return DotResult.failure(e)


func _to_string() -> String:
	return "DotResult(ok)" if ok else "DotResult(%s)" % str(error)
