class_name DotError
extends RefCounted

## A failure with a stable machine-readable code and a human-readable message.
##
## Every fallible operation in the dot-* family returns a [DotResult] carrying
## one of these rather than an [enum Error] int, because the interesting part of
## a failure here is almost never "which of Godot's 50 error constants" — it is
## whether the caller should retry, re-authenticate, or give up.
##
## [member code] is the contract. Callers branch on it and it must not change
## meaning between versions. [member message] is for humans and may be reworded
## freely; [member detail] carries the parts that belong in a log but not in a
## player-facing string (URLs, peer addresses, response bodies).

# --- Transport / IO ---------------------------------------------------------
const CODE_NETWORK := "network"              ## Connection failed or dropped.
const CODE_TIMEOUT := "timeout"              ## Deadline exceeded.
const CODE_HTTP := "http"                    ## Non-2xx response.
const CODE_IO := "io"                        ## Local filesystem failure.
const CODE_QUOTA := "quota"                  ## Out of storage (or browser quota).

# --- Data ------------------------------------------------------------------
const CODE_PARSE := "parse"                  ## Malformed payload.
const CODE_INVALID := "invalid"              ## Well-formed but semantically wrong.
const CODE_INTEGRITY := "integrity"          ## Hash or signature mismatch.
const CODE_VERSION := "version"              ## Incompatible protocol/content version.

# --- Authorization ---------------------------------------------------------
const CODE_AUTH := "auth"                    ## Not authenticated.
const CODE_FORBIDDEN := "forbidden"          ## Authenticated but not permitted.
const CODE_RATE_LIMITED := "rate_limited"    ## Slow down.

# --- Lifecycle -------------------------------------------------------------
const CODE_CANCELLED := "cancelled"          ## Caller aborted the operation.
const CODE_UNSUPPORTED := "unsupported"      ## Not possible on this platform.
const CODE_STATE := "state"                  ## Called in the wrong state.
const CODE_INTERNAL := "internal"            ## A bug on our side.

## Codes that a caller may reasonably retry without changing anything.
const RETRYABLE_CODES: Array[String] = [
	CODE_NETWORK,
	CODE_TIMEOUT,
	CODE_HTTP,
	CODE_RATE_LIMITED,
]

var code: String = CODE_INTERNAL
var message: String = ""
var detail: String = ""

## Seconds the caller should wait before retrying. -1 when unknown.
var retry_after: float = -1.0

## Populated when the failure originated from an HTTP request.
var http_status: int = 0

## Free-form structured context for logs. Never shown to players.
var context: Dictionary = {}


static func make(
	p_code: String,
	p_message: String,
	p_detail: String = ""
) -> DotError:
	var e := DotError.new()
	e.code = p_code
	e.message = p_message
	e.detail = p_detail
	return e


## Convenience for the very common "HTTP said no" case.
static func from_http(status: int, body: String = "") -> DotError:
	var e := DotError.new()
	e.http_status = status
	e.detail = body

	if status == 401:
		e.code = CODE_AUTH
		e.message = "Not signed in."
	elif status == 403:
		e.code = CODE_FORBIDDEN
		e.message = "Not allowed."
	elif status == 404:
		e.code = CODE_INVALID
		e.message = "Not found."
	elif status == 429:
		e.code = CODE_RATE_LIMITED
		e.message = "Too many requests."
	elif status >= 500:
		e.code = CODE_HTTP
		e.message = "The server is having trouble."
	else:
		e.code = CODE_HTTP
		e.message = "Request failed (HTTP %d)." % status

	return e


## Wraps a Godot [enum Error] so engine calls can join the same result flow.
static func from_engine(err: int, what: String = "") -> DotError:
	var e := DotError.new()
	e.code = CODE_IO
	e.message = "%s failed." % what if what != "" else "Operation failed."
	e.detail = "engine error %d (%s)" % [err, error_string(err)]
	return e


func is_retryable() -> bool:
	return RETRYABLE_CODES.has(code)


func _to_string() -> String:
	var s := "[%s] %s" % [code, message]
	if detail != "":
		s += " (%s)" % detail
	return s
