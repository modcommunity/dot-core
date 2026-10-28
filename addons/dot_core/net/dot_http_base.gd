@tool
extends Node

## Settings, header building and the HTTPRequest pool behind [DotHttp]; use [DotHttp].


## Concurrent [HTTPRequest] children kept alive.
## Each in-flight request needs its own node; the ceiling stops a 900-file manifest creating 900 sockets.
const MAX_POOL := 16

@export_group("Endpoint")

## Prepended to any path not starting with a scheme.
## Repoints callers at a staging backbone by changing one field.
@export var base_url: String = ""

## Sent with every request unless overridden per call.
@export var default_headers: Dictionary = {}

## Value for the [code]User-Agent[/code] header, so the backbone's audit log can tell a game server from a browser.
## Ignored on web, where setting one only costs a CORS preflight ([method _build_headers]).
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
## Without jitter, 40 clients retrying after a restart collide on every attempt.
@export_range(0.0, 1.0, 0.01) var retry_jitter: float = 0.3

@export_group("Transfer")

## Accept and transparently decompress gzip.
@export var accept_gzip: bool = true

## Bytes per read. 0 uses the engine default.
## HTTPRequest reads one chunk per frame without threads, so this is the per-frame ceiling (64 KiB gave ~190 KiB/s). Default from [method default_chunk_size].
@export var download_chunk_size: int = default_chunk_size()

## Read downloads on a worker thread. Off by default, ignored without [method DotPlatform.has_threads].
## Default from [method default_use_threads].
@export var use_threads: bool = default_use_threads()

const DEFAULT_CHUNK_SIZE := 1048576
const MAX_CHUNK_SIZE := 16777216

## Chunk size from [code]--dot-http-chunk=N[/code], env [code]DOT_HTTP_CHUNK_SIZE[/code],
## project setting [code]dot/http/download_chunk_size[/code], then 1 MiB; clamped to 16 MiB.
static func default_chunk_size() -> int:
	var v: Variant = _setting("dot-http-chunk", "DOT_HTTP_CHUNK_SIZE", "dot/http/download_chunk_size", DEFAULT_CHUNK_SIZE)
	return clampi(int(v), 0, MAX_CHUNK_SIZE)


## Threaded reads, opt-in: [code]--dot-http-threads[/code] / [code]=1[/code], env
## [code]DOT_HTTP_THREADS[/code], or project setting [code]dot/http/use_threads[/code].
static func default_use_threads() -> bool:
	return str(_setting("dot-http-threads", "DOT_HTTP_THREADS", "dot/http/use_threads", false)) in ["true", "1", "yes", "on", ""]


static func _setting(arg: String, env: String, project: String, fallback: Variant) -> Variant:
	for a in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a == "--" + arg:
			return ""
		if a.begins_with("--" + arg + "="):
			return a.substr(arg.length() + 3)
	var e := OS.get_environment(env)
	if e != "":
		return e
	return ProjectSettings.get_setting(project, fallback)

@export_range(0, 20, 1) var max_redirects: int = 8

## Refuse responses larger than this. 0 is unlimited.
## Guards against a content host streaming until a phone kills the process.
@export var max_response_bytes: int = 0

var _pool: Array[HTTPRequest] = []
var _in_flight: int = 0

## Nodes handed out by [method _acquire] and not yet released.
## Busy-ness cannot be read off the node (one given request_raw() this frame still reads DISCONNECTED).
var _busy: Array[HTTPRequest] = []
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


## Joins [member base_url] with a path, leaving absolute URLs untouched.
func resolve_url(path: String) -> String:
	if path.contains("://"):
		return path
	if base_url == "":
		return path
	return base_url.trim_suffix("/") + "/" + path.trim_prefix("/")


func _build_headers(extra: Dictionary) -> PackedStringArray:
	var merged := {}

	# The browser owns User-Agent and Accept-Encoding: forwarding them turns every
	# cross-origin call into a CORS preflight failure, so they are not sent on web.
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
## Header names are case-insensitive and real servers disagree (`ETag`, `etag`).
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
## Tokens and signed URLs live in query parameters.
func _redact(url: String) -> String:
	var idx := url.find("?")
	return url if idx < 0 else url.substr(0, idx) + "?…"


## The tighter of [param max_bytes] and [member max_response_bytes] as a body_size_limit; -1 for none.
## Set on every request, so a pooled node never keeps the last caller's cap.
func _limit_for(max_bytes: int) -> int:
	if max_bytes > 0 and max_response_bytes > 0:
		return mini(max_bytes, max_response_bytes)
	if max_bytes > 0:
		return max_bytes
	return max_response_bytes if max_response_bytes > 0 else -1


func _acquire() -> HTTPRequest:
	for req in _pool:
		# Both tests, and both are needed. `_busy` covers the node we handed out this
		# frame that has not connected yet; the status covers a node released while its
		# connection is still winding down.
		if _busy.has(req):
			continue
		if req.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
			_busy.append(req)
			return req

	if _pool.size() >= MAX_POOL:
		return null

	var req := HTTPRequest.new()
	req.timeout = timeout_sec

	# Never gzip on web: the browser already decoded the body, and Godot would inflate
	# the plain bytes a second time and fail the download.
	req.accept_gzip = accept_gzip and not OS.has_feature("web")
	req.max_redirects = max_redirects
	if download_chunk_size > 0:
		req.download_chunk_size = download_chunk_size
	if max_response_bytes > 0:
		req.body_size_limit = max_response_bytes

	# use_threads must stay false on single-threaded web builds; setting it
	# there is not an error, it simply never takes effect and hides the reason
	# requests still block.
	req.use_threads = use_threads and DotPlatform.has_threads()

	add_child(req)
	_pool.append(req)
	_busy.append(req)
	return req


func _release(req: HTTPRequest) -> void:
	_busy.erase(req)

	# Nodes are kept rather than freed: connection reuse across requests to the
	# same host is most of the benefit, and a token refresh followed by three API
	# calls should not open four TLS sessions.
	if _in_flight == 0 and _busy.is_empty() and _pool.size() > 4:
		for extra in _pool.slice(4):
			extra.queue_free()
		_pool = _pool.slice(0, 4)
