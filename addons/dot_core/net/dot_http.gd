@tool
class_name DotHttp
extends "res://addons/dot_core/net/dot_http_base.gd"

## An HTTP client that works identically on desktop, mobile and in a browser.
##
## [HTTPRequest], not [HTTPClient], which does not exist on web. Retries (jittered backoff)
## cover transport failures, 5xx and 429 only: never 4xx, which would lock an account out.
## On web a request that fails with no useful error is almost always CORS.
## [codeblock]
## var http := DotHttp.new()
## add_child(http)
## var res := await http.get_json("/api/app/v1/me", {"Authorization": "Bearer …"})
## [/codeblock]

const CHANNEL := "http"


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


## GET raw bytes. [param max_bytes] > 0 refuses a longer body (as does [member max_response_bytes]).
func get_bytes(path: String, headers: Dictionary = {}, max_bytes: int = 0) -> DotResult:
	var res := await _capped(max_bytes, HTTPClient.METHOD_GET, path, PackedByteArray(), headers, true)
	if not res.ok:
		return res
	var response: Dictionary = res.value
	return DotResult.success(response["body"])


## Performs a request with retries. The value is [code]{status, headers, body, body_text,
## attempts}[/code]; a failure carries the status and the first 512 bytes of the body.
func request(
	method: int,
	path: String,
	body: PackedByteArray = PackedByteArray(),
	headers: Dictionary = {},
	decode_text: bool = true
) -> DotResult:
	return await _request(method, path, body, headers, decode_text, 0)


## [method request] when uncapped, so a subclass overriding it still sees every call it saw before.
func _capped(max_bytes: int, method: int, path: String, body: PackedByteArray, headers: Dictionary, decode_text: bool) -> DotResult:
	if max_bytes <= 0:
		return await request(method, path, body, headers, decode_text)
	return await _request(method, path, body, headers, decode_text, max_bytes)


func _request(
	method: int,
	path: String,
	body: PackedByteArray,
	headers: Dictionary,
	decode_text: bool,
	max_bytes: int
) -> DotResult:
	var url := resolve_url(path)
	var header_list := _build_headers(headers)

	var attempt := 0
	var last: DotResult = null

	while attempt <= max_retries:
		attempt += 1

		last = await _attempt(method, url, body, header_list, decode_text, max_bytes)

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
	header_list: PackedStringArray,
	decode_text: bool = true,
	max_bytes: int = 0
) -> DotResult:
	var req := _acquire()
	if req == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"Too many concurrent HTTP requests.",
			"pool limit is %d" % MAX_POOL
		)
	req.body_size_limit = _limit_for(max_bytes)

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
		out = _interpret(completed, url, decode_text)

	_in_flight -= 1
	_release(req)
	return out


## Turns [signal HTTPRequest.request_completed]'s four arguments into a result.
func _interpret(
	completed: Array, url: String, decode_text: bool = true
) -> DotResult:
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

	# body_text is skipped for binary callers: UTF-8 decoding a PNG doubles its memory and
	# logs an engine error per file. Default on because existing callers read it.
	var out := {
		"status": status,
		"headers": headers,
		"body": body,
	}

	if decode_text:
		out["body_text"] = body.get_string_from_utf8()

	return DotResult.success(out)


## Maps [enum HTTPRequest.Result] to a [DotError], keeping retryable apart from not. On web
## these collapse to CANT_CONNECT because [code]fetch()[/code] will not say why (often CORS).
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


## Downloads to a file, not memory. [param range_start] resumes a partial file (the caller
## verified its bytes); [param max_bytes] > 0 caps the body. Value: [code]{status, headers, size, resumed}[/code].
func download_to_file(
	url_or_path: String,
	dest_path: String,
	range_start: int = 0,
	headers: Dictionary = {},
	max_bytes: int = 0
) -> DotResult:
	var url := resolve_url(url_or_path)

	var parent := DotPaths.ensure_parent_dir(dest_path)
	if not parent.ok:
		return parent

	# On web a 2xx can leave no file behind. Detect it once (see below) and fall back
	# to memory, rather than keeping a list of platforms that would go stale.
	if not _engine_writes_downloads:
		return await _download_in_memory(url, dest_path, range_start, headers, max_bytes)

	var merged := headers.duplicate()

	# HTTPRequest truncates download_file, so a ranged body goes to a sibling and is
	# joined on: a failed resume then leaves the partial untouched.
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
	req.body_size_limit = _limit_for(max_bytes)
	req.download_chunk_size = download_chunk_size if download_chunk_size > 0 else DEFAULT_CHUNK_SIZE

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
			# Local partial is at least as long as the resource: fail so the caller restarts from zero.
			out = DotResult.fail(
				DotError.CODE_INVALID,
				"The server rejected the resume range.",
				"local partial may be longer than the remote file"
			)
		elif status < 200 or status >= 300:
			out = DotResult.failure(DotError.from_http(status))
		else:
			# Only 206 continues what is on disk; 200 is the whole body.
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
					# Whole resource: replace, or the prefix lands twice.
					DotLog.debug(
						CHANNEL,
						"server ignored Range; restarted from zero",
						{"url": _redact(url)}
					)
					joined = DotPaths.replace_file(dest_path, resume_target)

			if not joined.ok:
				out = joined
			else:
								# No flush: web `user://` sync is async and overlapping calls lose files; a partial
								# costs one re-download and DotCloudStore flushes per committed object. A 2xx with
								# no file on disk is a failure: HTTPRequest does not say whether its write landed.
				var written := DotPaths.file_size(dest_path)

				if not FileAccess.file_exists(dest_path):
					# Said once: parallel downloads each find the same thing.
					if _engine_writes_downloads:
						DotLog.warn(
							CHANNEL,
							"this platform's HTTP client does not write downloads to "
							+ "a file; fetching into memory from here on",
							{"status": status, "claimed_bytes": written}
						)

					_engine_writes_downloads = false
					out = DotResult.success({"retry_in_memory": true})
				else:
					out = DotResult.success({
						"status": status,
						"headers": _parse_headers(completed[2]),
						"size": written,
						"resumed": resumed,
					})

	_in_flight -= 1
	req.download_file = ""
	_release(req)

	# A failed attempt keeps nothing resumable; the next one re-requests the range.
	if resume_target != "" and FileAccess.file_exists(resume_target):
		DirAccess.remove_absolute(resume_target)

	if out.ok and (out.value as Dictionary).get("retry_in_memory", false):
		return await _download_in_memory(url, dest_path, range_start, headers, max_bytes)

	return out


## Whether [HTTPRequest] actually writes [code]download_file[/code]; assumed true, demoted on the first success that leaves no file.
static var _engine_writes_downloads: bool = true


## [method download_to_file] for a platform whose HTTP client will not write a file: the body is held in memory and written through [DotPaths] (which flushes the web filesystem). Content objects are file-sized, so RAM is bounded.
func _download_in_memory(
	url: String,
	dest_path: String,
	range_start: int,
	headers: Dictionary,
	max_bytes: int = 0
) -> DotResult:
	var merged := headers.duplicate()

	if range_start > 0:
		merged["Range"] = "bytes=%d-" % range_start

	var res := await _capped(max_bytes, HTTPClient.METHOD_GET, url, PackedByteArray(), merged, false)

	if not res.ok:
		return res

	var response: Dictionary = res.value
	var status := int(response.get("status", 0))
	var body: PackedByteArray = response.get("body", PackedByteArray())

	# 200 (Range ignored) REPLACES what is on disk; 206 continues it.
	var resumed := status == 206

	var written := (
		DotPaths.append_bytes(dest_path, body) if resumed and range_start > 0
		else DotPaths.write_bytes(dest_path, body)
	)

	if not written.ok:
		return written

	return DotResult.success({
		"status": status,
		"headers": response.get("headers", {}),
		"size": DotPaths.file_size(dest_path),
		"resumed": resumed,
	})


## Asks with a HEAD request whether a URL supports resuming: [code]{size, accepts_ranges, etag}[/code].
## On web false can mean the host does not expose the header through CORS.
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


func describe() -> Dictionary:
	return {
		"base_url": base_url,
		"pool": _pool.size(),
		"in_flight": _in_flight,
		"timeout": timeout_sec,
		"retries": max_retries,
	}
