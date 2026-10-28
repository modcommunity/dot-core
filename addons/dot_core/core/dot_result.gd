class_name DotResult
extends RefCounted

## The return type of every fallible operation in the dot-* family. Not null (loses the
## reason) or an Array pair (loses types); reading [member value] on a failure pushes an error.
## [code]if not res.ok: DotLog.warn("store", res.error); return[/code]

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


## The success payload. Reading it on a failed result is a programming error (the [member ok]
## check was skipped): it complains and returns null so any crash is at the real call site.
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
func value_or(default: Variant) -> Variant:
	return _value if ok else default


## The failure code, or [code]""[/code] on success. Safe to call either way.
func code() -> String:
	return "" if ok or error == null else error.code


func is_retryable() -> bool:
	return (not ok) and error != null and error.is_retryable()


## Re-wraps a failure with a new message, keeping the original as detail.
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
