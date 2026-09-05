@tool
class_name DotHttp
extends Node

## An HTTP client that works identically on desktop, mobile and in a browser.
##
## [b]Why not [HTTPClient].[/b] It does not exist on web — the browser forces
## every request through [code]fetch()[/code], and only [HTTPRequest] is wired to
## that. So everything in dot-* that talks HTTP uses [HTTPRequest], which means
## living with its quirks: it is a [Node], it handles one request at a time, and
## it reports transport failures and HTTP failures through the same signal with
## different arguments. This wraps all of that into something awaitable.
##
## [codeblock]
## var http := DotHttp.new()
## add_child(http)
## http.base_url = "https://example.com"
##
## var res := await http.get_json("/api/app/v1/me", {"Authorization": "Bearer …"})
## if res.ok:
##     print(res.value["data"]["username"])
## [/codeblock]
##
## [b]Retries.[/b] Automatic, with jittered exponential backoff, for transport
## failures and 5xx/429 only. Never for 4xx: a 401 will be a 401 again, and
## retrying a rejected credential three times is how an account gets locked out.
## [code]Retry-After[/code] is honoured when present.
##
## [b]On CORS.[/b] In a browser, every response header this class can read and
## every cross-origin request it can make is subject to the server's CORS policy.
## A request that works on desktop and fails on web with no useful error is
## almost always CORS; see dot-cloud's CLAUDE.md for the headers a content host
## must send.

const CHANNEL := "http"

## Concurrent [HTTPRequest] children kept alive.
##
## Each in-flight request needs its own node. The ceiling stops a caller that
## loops over a 900-file manifest from creating 900 nodes and 900 sockets;
## dot-cloud's downloader has its own slot limit on top of this.
const MAX_POOL := 16

@export_group("Endpoint")

## Prepended to any path not starting with a scheme.
##
## Lets callers pass [code]"/api/app/v1/me"[/code] and be repointed at a staging
## backbone by changing one field.
@export var base_url: String = ""

## Sent with every request unless overridden per call.
@export var default_headers: Dictionary = {}

## Value for the [code]User-Agent[/code] header.
##
## Servers legitimately rate-limit or block unidentified clients, and the
## backbone's audit log is more useful when it can tell a game server from a
## browser.
##
## [b]Ignored on the web[/b], where the browser sends its own and setting one
## only costs a CORS preflight -- see [method _build_headers].
@export var user_agent: String = "dot-core/0.1 (Godot)"

@export_group("Timeouts")

## Per-attempt timeout in seconds. 0 disables.
@export_range(0.0, 600.0, 0.5) var timeout_sec: float = 20.0

@export_group("Retries")

## Extra attempts after the first. 0 disables retrying.
@export_range(0, 10, 1) var max_retries: int = 2

## Delay before the first retry. Doubles each attempt.
@export_range(0.05, 30.0, 0.05) var retry_base_sec: float = 0.5

## Ceiling on the backoff delay.
@export_range(0.5, 300.0, 0.5) var retry_max_sec: float = 15.0

## Random fraction added to each delay, to spread a thundering herd.
##
## Matters when a server restarts and 40 clients retry in lockstep: without
## jitter they collide on every attempt and the backoff never helps.
@export_range(0.0, 1.0, 0.01) var retry_jitter: float = 0.3

@export_group("Transfer")

## Accept and transparently decompress gzip.
@export var accept_gzip: bool = true

## Bytes per read. 0 uses the engine default.
##
## Raised for content downloads, where the default's small reads add measurable
## overhead across hundreds of megabytes.
@export var download_chunk_size: int = 65536

@export_range(0, 20, 1) var max_redirects: int = 8

## Refuse responses larger than this. 0 is unlimited.
##
## A guard against a hostile or broken content host streaming until the process
## runs out of memory — which on a phone is a kill, not an error.
@export var max_response_bytes: int = 0

var _pool: Array[HTTPRequest] = []
var _in_flight: int = 0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


# --- Convenience -----------------------------------------------------------

## GET, parsing the response as JSON.
func get_json(path: String, headers: Dictionary = {}) -> DotResult:
	var res := await request(HTTPClient.METHOD_GET, path, PackedByteArray(), headers)
	if not res.ok:
		return res
	return _parse_json(res.value)


## POST a JSON body, parsing the response as JSON.
func post_json(
	path: String,
	body: Variant,
	headers: Dictionary = {}
) -> DotResult:
	var merged := headers.duplicate()
	merged["Content-Type"] = "application/json"

	var res := await request(
		HTTPClient.METHOD_POST,
		path,
		JSON.stringify(body).to_utf8_buffer(),
		merged
	)
	if not res.ok:
		return res
	return _parse_json(res.value)


func put_json(
	path: String,
	body: Variant,
	headers: Dictionary = {}
) -> DotResult:
	var merged := headers.duplicate()
	merged["Content-Type"] = "application/json"

	var res := await request(
		HTTPClient.METHOD_PUT,
		path,
		JSON.stringify(body).to_utf8_buffer(),
		merged
	)
	if not res.ok:
		return res
	return _parse_json(res.value)


## GET raw bytes.
func get_bytes(path: String, headers: Dictionary = {}) -> DotResult:
	var res := await request(
		HTTPClient.METHOD_GET, path, PackedByteArray(), headers
	)
	if not res.ok:
		return res
	var response: Dictionary = res.value
	return DotResult.success(response["body"])


# --- Core request ----------------------------------------------------------

## Performs a request with retries.
##
## On success the value is
## [code]{status, headers, body, body_text, attempts}[/code]. On failure the
## error carries the status and the first 512 bytes of the body as detail, which
## is almost always where the server explained itself.
func request(
	method: int,
	path: String,
	body: PackedByteArray = PackedByteArray(),
	headers: Dictionary = {}
) -> DotResult:
	var url := resolve_url(path)
	var header_list := _build_headers(headers)

	var attempt := 0
	var last: DotResult = null

	while attempt <= max_retries:
		attempt += 1

		last = await _attempt(method, url, body, header_list)

		if last.ok:
			var v: Dictionary = last.value
			v["attempts"] = attempt
			return DotResult.success(v)

		if attempt > max_retries or not last.is_retryable():
			break

		var delay := _backoff_delay(attempt, last.error)
		DotLog.debug(
			CHANNEL,
			"retrying",
			{
				"url": _redact(url),
				"attempt": attempt,
				"in": "%.2fs" % delay,
				"why": last.code(),
			}
		)

		var timer := get_tree().create_timer(delay)
		await timer.timeout

	return last


func _attempt(
	method: int,
	url: String,
	body: PackedByteArray,
	header_list: PackedStringArray
) -> DotResult:
	var req := _acquire()
	if req == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"Too many concurrent HTTP requests.",
			"pool limit is %d" % MAX_POOL
		)

	_in_flight += 1

	var out: DotResult
	# request_raw takes a PackedByteArray; request() takes a String and would
	# mangle a binary body through UTF-8 conversion.
	var err := req.request_raw(url, header_list, method, body)

	if err != OK:
		out = DotResult.failure(
			DotError.from_engine(err, "starting request to %s" % _redact(url))
		)
	else:
		var completed: Array = await req.request_completed
		out = _interpret(completed, url)

	_in_flight -= 1
	_release(req)
	return out


## Turns [signal HTTPRequest.request_completed]'s four arguments into a result.
func _interpret(completed: Array, url: String) -> DotResult:
	var result: int = completed[0]
	var status: int = completed[1]
	var raw_headers: PackedStringArray = completed[2]
	var body: PackedByteArray = completed[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		return DotResult.failure(_transport_error(result, url))

	var headers := _parse_headers(raw_headers)

	if status < 200 or status >= 300:
		var e := DotError.from_http(status, body.get_string_from_utf8().substr(0, 512))
		if headers.has("retry-after"):
			var ra := str(headers["retry-after"]).strip_edges()
			if ra.is_valid_float():
				e.retry_after = ra.to_float()
		# 5xx and 429 are worth retrying; from_http maps them to codes that
		# is_retryable() already accepts, so nothing more is needed here.
		return DotResult.failure(e)

	if max_response_bytes > 0 and body.size() > max_response_bytes:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Response is larger than the configured limit.",
			"%d > %d bytes" % [body.size(), max_response_bytes]
		)

	return DotResult.success({
		"status": status,
		"headers": headers,
		"body": body,
		"body_text": body.get_string_from_utf8(),
	})


## Maps [enum HTTPRequest.Result] to a [DotError].
##
## The distinction that matters is retryable-or-not: a connection that dropped
## is worth another go, a TLS handshake that failed will fail identically. On web
## these all collapse to CANT_CONNECT because [code]fetch()[/code] deliberately
## refuses to say why — including when the real cause is CORS — which is why the
## detail mentions it.
func _transport_error(result: int, url: String) -> DotError:
	var e := DotError.new()
	e.context = {"url": _redact(url), "result": result}

	match result:
		HTTPRequest.RESULT_TIMEOUT:
			e.code = DotError.CODE_TIMEOUT
			e.message = "The request timed out."
		HTTPRequest.RESULT_CANT_CONNECT:
			e.code = DotError.CODE_NETWORK
			e.message = "Could not connect."
			if DotPlatform.is_web():
				e.detail = "in a browser this is usually a CORS or mixed-content block"
		HTTPRequest.RESULT_CANT_RESOLVE:
			e.code = DotError.CODE_NETWORK
			e.message = "Could not resolve the host."
		HTTPRequest.RESULT_CONNECTION_ERROR:
			e.code = DotError.CODE_NETWORK
			e.message = "The connection failed."
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			# Not retryable: a bad certificate is bad every time, and retrying
			# hides a real misconfiguration behind a slow failure.
			e.code = DotError.CODE_INVALID
			e.message = "The secure connection could not be established."
			e.detail = "certificate rejected"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			e.code = DotError.CODE_INVALID
			e.message = "Too many redirects."
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			e.code = DotError.CODE_INVALID
			e.message = "The response was too large."
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, \
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			e.code = DotError.CODE_IO
			e.message = "Could not write the downloaded file."
		_:
			e.code = DotError.CODE_NETWORK
			e.message = "The request failed."
			e.detail = "HTTPRequest result %d" % result

	return e


# --- Downloads -------------------------------------------------------------

## Downloads to a file rather than into memory.
##
## The only sane way to fetch content: a 500 MB PCK read into a
## [PackedByteArray] costs 500 MB of RAM plus a copy, and on a phone that is a
## termination.
##
## [param range_start] resumes a partial file by sending a [code]Range[/code]
## header. The caller is responsible for having verified that the existing bytes
## belong to this resource — see dot-cloud's store, which keys partials by
## content hash so a resumed transfer cannot splice two different files together.
##
## On success the value is [code]{status, headers, size, resumed}[/code].
func download_to_file(
	url_or_path: String,
	dest_path: String,
	range_start: int = 0,
	headers: Dictionary = {}
) -> DotResult:
	var url := resolve_url(url_or_path)

	var parent := DotPaths.ensure_parent_dir(dest_path)
	if not parent.ok:
		return parent

	var merged := headers.duplicate()

	# HTTPRequest has no append mode: it truncates whatever download_file points
	# at. A ranged body written straight to dest_path therefore *replaces* the
	# partial with its own tail, which looks like a success and is a corrupt
	# file. So the response lands in a sibling and is joined on below — which
	# also means a resume that fails leaves the partial untouched rather than
	# destroying the bytes it was trying to extend.
	var resume_target := ""

	if range_start > 0:
		merged["Range"] = "bytes=%d-" % range_start
		resume_target = dest_path + ".resume"

	var header_list := _build_headers(merged)

	var req := _acquire()
	if req == null:
		return DotResult.fail(
			DotError.CODE_STATE, "Too many concurrent HTTP requests."
		)

	req.download_file = resume_target if resume_target != "" else dest_path
	req.download_chunk_size = download_chunk_size if download_chunk_size > 0 else 65536

	_in_flight += 1

	var out: DotResult
	var err := req.request(url, header_list, HTTPClient.METHOD_GET)

	if err != OK:
		out = DotResult.failure(
			DotError.from_engine(err, "downloading %s" % _redact(url))
		)
	else:
		var completed: Array = await req.request_completed
		var status: int = completed[1]
		var result: int = completed[0]

		if result != HTTPRequest.RESULT_SUCCESS:
			out = DotResult.failure(_transport_error(result, url))
		elif status == 416:
			# "Range not satisfiable" means the local partial is at least as
			# long as the resource. Treated as a failure the caller retries
			# from zero, because the alternative is trusting a file we cannot
			# explain.
			out = DotResult.fail(
				DotError.CODE_INVALID,
				"The server rejected the resume range.",
				"local partial may be longer than the remote file"
			)
		elif status < 200 or status >= 300:
			out = DotResult.failure(DotError.from_http(status))
		else:
			# A server that ignores Range replies 200 with the whole body; only
			# 206 means what arrived is a continuation of what is on disk.
			var resumed := status == 206
			var joined := DotResult.success(0)

			if resume_target != "":
				if resumed:
					joined = DotPaths.append_file(
						dest_path, resume_target, range_start
					)
					if joined.ok:
						DirAccess.remove_absolute(resume_target)
					else:
						joined = joined.wrap(
							"joining the resumed range onto '%s'" % dest_path
						)
				else:
					# The body is the whole resource, so the sibling *is* the
					# file. Replacing rather than appending is the difference
					# between the file and the file with its prefix twice.
					DotLog.debug(
						CHANNEL,
						"server ignored Range; restarted from zero",
						{"url": _redact(url)}
					)
					joined = DotPaths.replace_file(dest_path, resume_target)

			if not joined.ok:
				out = joined
			else:
				DotWeb.sync_filesystem()
				out = DotResult.success({
					"status": status,
					"headers": _parse_headers(completed[2]),
					"size": DotPaths.file_size(dest_path),
					"resumed": resumed,
				})

	_in_flight -= 1
	req.download_file = ""
	_release(req)

	# Nothing resumable survives a failed attempt: the next one re-requests the
	# same range. Leaving the sibling behind would grow a second copy of every
	# interrupted download beside the first.
	if resume_target != "" and FileAccess.file_exists(resume_target):
		DirAccess.remove_absolute(resume_target)

	return out


## Asks whether a URL supports resuming, with a HEAD request.
##
## Returns [code]{size, accepts_ranges, etag}[/code]. On web
## [code]accepts_ranges[/code] is only true when the host also exposes the
## header through CORS, so a false here means "cannot rely on it", not
## necessarily "the server lacks it".
func probe(url_or_path: String, headers: Dictionary = {}) -> DotResult:
	var res := await request(
		HTTPClient.METHOD_HEAD, url_or_path, PackedByteArray(), headers
	)
	if not res.ok:
		return res

	var response: Dictionary = res.value
	var h: Dictionary = response["headers"]

	return DotResult.success({
		"size": int(str(h.get("content-length", "-1"))),
		"accepts_ranges": str(h.get("accept-ranges", "")).to_lower() == "bytes",
		"etag": str(h.get("etag", "")),
		"content_type": str(h.get("content-type", "")),
	})


# --- Helpers ---------------------------------------------------------------

## Joins [member base_url] with a path, leaving absolute URLs untouched.
func resolve_url(path: String) -> String:
	if path.contains("://"):
		return path
	if base_url == "":
		return path
	return base_url.trim_suffix("/") + "/" + path.trim_prefix("/")


func _build_headers(extra: Dictionary) -> PackedStringArray:
	var merged := {}

	# THE BROWSER OWNS THESE TWO, and the platforms disagree about whether a page
	# may set them anyway: Chrome treats `User-Agent` as a forbidden header and
	# drops it without a word, Firefox forwards it. Forwarding is the damaging
	# half. A header outside the CORS safelist turns every cross-origin call into
	# one the server's preflight must name explicitly, so a backbone that allows
	# `authorization` and `content-type` -- a reasonable list, and the one the TMC
	# backbone shipped -- answers the preflight, refuses the request, and does it
	# in ONE browser. The game then signs nobody in for a reason no log records.
	# `Accept-Encoding` is refused by both browsers outright.
	#
	# Neither is a loss: the browser sends its own User-Agent and negotiates its
	# own encoding, so on the web these lines were never anything but a way to
	# fail a preflight.
	var web := OS.has_feature("web")

	if user_agent != "" and not web:
		merged["User-Agent"] = user_agent
	if accept_gzip and not web:
		merged["Accept-Encoding"] = "gzip"

	for k in default_headers:
		merged[str(k)] = str(default_headers[k])
	for k in extra:
		merged[str(k)] = str(extra[k])

	var out := PackedStringArray()
	for k in merged:
		out.append("%s: %s" % [k, merged[k]])
	return out


## Lowercases header names so lookups do not depend on a server's casing.
##
## HTTP header names are case-insensitive and real servers disagree
## (`ETag`, `etag`, `Etag`), so a case-sensitive lookup works until it does not.
func _parse_headers(raw: PackedStringArray) -> Dictionary:
	var out := {}
	for line in raw:
		var idx := line.find(":")
		if idx <= 0:
			continue
		var key := line.substr(0, idx).strip_edges().to_lower()
		out[key] = line.substr(idx + 1).strip_edges()
	return out


func _parse_json(response: Variant) -> DotResult:
	var r: Dictionary = response
	var text: String = r["body_text"]

	if text.strip_edges() == "":
		return DotResult.success({})

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The server sent malformed JSON.",
			"line %d: %s" % [json.get_error_line(), json.get_error_message()]
		)

	return DotResult.success(json.data)


func _backoff_delay(attempt: int, err: DotError) -> float:
	# An explicit Retry-After beats our guess: the server knows its own limits
	# and ignoring it is how a client gets banned rather than throttled.
	if err != null and err.retry_after > 0.0:
		return minf(err.retry_after, retry_max_sec)

	var delay := retry_base_sec * pow(2.0, float(attempt - 1))
	delay = minf(delay, retry_max_sec)
	delay += delay * retry_jitter * _rng.randf()
	return delay


## Strips query strings from URLs before they reach a log.
##
## Tokens and signed URLs live in query parameters, and a log line is the most
## commonly pasted artefact there is.
func _redact(url: String) -> String:
	var idx := url.find("?")
	return url if idx < 0 else url.substr(0, idx) + "?…"


# --- HTTPRequest pool -----------------------------------------------------

func _acquire() -> HTTPRequest:
	for req in _pool:
		# get_http_client_status() is the only reliable "is this node busy"
		# signal; a node whose request finished is DISCONNECTED again.
		if req.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
			return req

	if _pool.size() >= MAX_POOL:
		return null

	var req := HTTPRequest.new()
	req.timeout = timeout_sec
	req.accept_gzip = accept_gzip
	req.max_redirects = max_redirects
	if download_chunk_size > 0:
		req.download_chunk_size = download_chunk_size
	if max_response_bytes > 0:
		req.body_size_limit = max_response_bytes

	# use_threads must stay false on single-threaded web builds; setting it
	# there is not an error, it simply never takes effect and hides the reason
	# requests still block.
	req.use_threads = DotPlatform.has_threads()

	add_child(req)
	_pool.append(req)
	return req


func _release(req: HTTPRequest) -> void:
	# Nodes are kept rather than freed: connection reuse across requests to the
	# same host is most of the benefit, and a token refresh followed by three API
	# calls should not open four TLS sessions.
	if _in_flight == 0 and _pool.size() > 4:
		for extra in _pool.slice(4):
			extra.queue_free()
		_pool = _pool.slice(0, 4)


func describe() -> Dictionary:
	return {
		"base_url": base_url,
		"pool": _pool.size(),
		"in_flight": _in_flight,
		"timeout": timeout_sec,
		"retries": max_retries,
	}
