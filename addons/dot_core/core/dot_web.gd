class_name DotWeb
extends RefCounted

## Access to the browser from GDScript, safely callable on every platform.
## Everything goes through [method Engine.get_singleton]: naming JavaScriptBridge fails to parse on desktop builds.
## Off-web each call is a no-op or a failed [DotResult], so callers can use it unguarded.

# No log channel: static bridges to the browser, each of which is a no-op or a failed
# DotResult off the web. Whether "not in a browser" or "no quota API" matters is the
# caller's decision, and on every desktop build it is the ordinary case.

static var _bridge: Object = null
static var _bridge_looked_up: bool = false

## Callbacks handed to JS are kept alive here.
## [method JavaScriptBridge.create_callback] does not retain its reference; a dropped one leaves JS calling freed memory.
static var _callbacks: Dictionary = {}


## The [code]JavaScriptBridge[/code] singleton, or null off-web.
static func bridge() -> Object:
	if not _bridge_looked_up:
		_bridge_looked_up = true
		if Engine.has_singleton("JavaScriptBridge"):
			_bridge = Engine.get_singleton("JavaScriptBridge")
	return _bridge


static func available() -> bool:
	return bridge() != null


## A global object from the page, without evaluating anything.
## Prefer to [method eval]: a CSP without 'unsafe-eval' refuses eval and Godot returns null, indistinguishable from an empty page.
## Returns null for an absent global and for a primitive (only objects are wrapped); park values on an object.
static func get_global(name: String) -> Variant:
	var b := bridge()
	if b == null:
		return null

	return b.call("get_interface", name)


## Evaluates JavaScript and returns its value; needs 'unsafe-eval' in the CSP (see [method get_global]).
## Only numbers, strings, booleans and null convert; stringify anything structured and use [method eval_json].
## [param use_global_scope] runs at global scope, for declarations that must outlive the call.
static func eval(code: String, use_global_scope: bool = false) -> Variant:
	var b := bridge()
	if b == null:
		return null
	return b.call("eval", code, use_global_scope)


## Evaluates JavaScript expected to produce a JSON string, and parses it.
## Fails with a [DotResult] rather than null, so "the browser said no" differs from "the browser said null".
static func eval_json(code: String, use_global_scope: bool = false) -> DotResult:
	if not available():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "Not running in a browser."
		)

	var raw: Variant = eval(code, use_global_scope)
	if raw == null:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"JavaScript returned no value.",
			code.substr(0, 200)
		)

	var parsed: Variant = JSON.parse_string(str(raw))
	if parsed == null:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"JavaScript returned unparseable JSON.",
			str(raw).substr(0, 200)
		)

	return DotResult.success(parsed)


## Creates a JS-callable wrapper around a GDScript [Callable] and roots it.
## Registering the same [param name] twice replaces the first. Returns null off-web.
static func create_callback(name: String, callable: Callable) -> Variant:
	var b := bridge()
	if b == null:
		return null

	var cb: Variant = b.call("create_callback", callable)
	_callbacks[name] = cb
	return cb


static func release_callback(name: String) -> void:
	_callbacks.erase(name)


## Flushes the emulated filesystem to IndexedDB; no-op off-web.
## On web [code]user://[/code] is an in-memory mirror persisted asynchronously, so a tab closed before the flush loses writes.
## dot-cloud calls it after each committed object, not once at the end.
static func sync_filesystem() -> void:
	var b := bridge()
	if b == null:
		return
	if b.has_method("force_fs_sync"):
		b.call("force_fs_sync")


## Best-effort storage quota, as [code]{"usage": bytes, "quota": bytes}[/code].
## Fails when the API is missing (older Safari); treat an unknown quota as normal and fall back to a configured ceiling.
static func estimate_storage() -> DotResult:
	if not available():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "Not running in a browser."
		)

	var probe: Variant = eval(
		"(navigator.storage && navigator.storage.estimate) ? 1 : 0", true
	)
	if int(probe if probe != null else 0) != 1:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"navigator.storage.estimate is unavailable."
		)

		# A JS Promise cannot be awaited from GDScript: park the result on a global and poll; it resolves in microseconds.
	eval(
		"""
		window.__dotStorageEstimate = null;
		navigator.storage.estimate().then(function (e) {
			window.__dotStorageEstimate = JSON.stringify({
				usage: e.usage || 0,
				quota: e.quota || 0
			});
		}).catch(function () {
			window.__dotStorageEstimate = '{"usage":0,"quota":0}';
		});
		""",
		true
	)

	var loop := Engine.get_main_loop()
	for _i in range(120):
		var raw: Variant = eval("window.__dotStorageEstimate", true)
		if raw != null:
			var parsed: Variant = JSON.parse_string(str(raw))
			if parsed is Dictionary:
				return DotResult.success(parsed)
			break
		if loop is SceneTree:
			await (loop as SceneTree).process_frame
		else:
			break

	return DotResult.fail(
		DotError.CODE_TIMEOUT, "Storage estimate did not resolve."
	)


## Asks the browser to make storage persistent so it is not evicted under pressure.
## Chrome grants silently, Firefox prompts, Safari ignores: always call, never rely on it.
static func request_persistent_storage() -> void:
	if not available():
		return
	eval(
		"""
		if (navigator.storage && navigator.storage.persist) {
			navigator.storage.persist().catch(function () {});
		}
		""",
		true
	)


## The page's origin, e.g. [code]https://example.com[/code]. Empty off-web.
## Needed for same-origin content URLs, which sidestep CORS.
static func origin() -> String:
	if not available():
		return ""
	var v: Variant = eval("window.location.origin", true)
	return str(v) if v != null else ""


## Query parameter from the page URL, for passing a server address into an
## embedded web build without rebuilding it.
static func query_param(key: String) -> String:
	if not available():
		return ""
	var v: Variant = eval(
		"new URLSearchParams(window.location.search).get(%s) || ''"
		% JSON.stringify(key),
		true
	)
	return str(v) if v != null else ""


## Whether the page is served over HTTPS.
## Decides whether a WebSocket must use [code]wss://[/code]: a secure page cannot open an insecure socket.
static func is_secure_context() -> bool:
	if not available():
		return false
	var v: Variant = eval("window.isSecureContext ? 1 : 0", true)
	return int(v if v != null else 0) == 1


## Whether the page itself was served over HTTPS.
## Not [method is_secure_context]: browsers treat http://localhost as a secure context, but mixed-content blocking
## (what decides whether [code]ws://[/code] may open) exempts exactly those origins; the wrong one breaks local tests.
static func is_https_page() -> bool:
	if not available():
		return false

	var v: Variant = eval("window.location.protocol === 'https:' ? 1 : 0", true)
	return int(v if v != null else 0) == 1


## Whether the page is on screen, as [code]document.hidden[/code] reports it.
## True off-web, deliberately: only a browser stops the main loop for a hidden window.
static func is_page_visible() -> bool:
	var doc: Variant = get_global("document")
	if doc == null:
		return true

		# Read with `.hidden`, never `.get("hidden")`: a [JavaScriptObject] routes `get` and `call` to JS method
		# invocations, so `.get("hidden")` fails with "obj[method] is not a function".
	var hidden: Variant = doc.hidden
	if hidden == null:
		return true
	return not bool(hidden)


## Calls [param callable] with a bool (visible) whenever the page is shown or hidden.
## The only warning a web build gets that its loop is about to stop: a hidden tab stops [code]requestAnimationFrame[/code],
## so nothing is polled or sent. The [Callable] must not [code]await[/code]. [param name] roots it ([method create_callback]); false off-web.
static func watch_visibility(name: String, callable: Callable) -> bool:
	var doc: Variant = get_global("document")
	if doc == null:
		return false

	var cb: Variant = create_callback(
		name,
		func(_args: Array) -> void:
			callable.call(is_page_visible())
	)
	if cb == null:
		return false

	# Called directly rather than through `.call("addEventListener", ...)`, for the
	# reason given in [method is_page_visible]: `.call` on a [JavaScriptObject] would
	# look for a `call` method on `document` itself.
	doc.addEventListener("visibilitychange", cb)
	return true


## Removes a listener registered by [method watch_visibility] and drops its root.
static func unwatch_visibility(name: String) -> void:
	var doc: Variant = get_global("document")
	if doc != null and _callbacks.has(name):
		doc.removeEventListener("visibilitychange", _callbacks[name])

	release_callback(name)
