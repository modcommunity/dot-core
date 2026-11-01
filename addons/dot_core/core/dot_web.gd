class_name DotWeb
extends RefCounted

## Access to the browser from GDScript, safely callable on every platform.
## Everything goes through [method Engine.get_singleton]: naming JavaScriptBridge fails to parse on desktop builds.
## Off-web each call is a no-op or a failed [DotResult], so callers can use it unguarded.

# Most of this class has no log channel: each call is a no-op or a failed DotResult off the web, and whether
# "not in a browser" matters is the caller's decision. Only the filesystem sync reports, on its own channel.
const SYNC_CHANNEL := "web.sync"

static var _bridge: Object = null
static var _bridge_looked_up: bool = false

## Callbacks handed to JS are kept alive here.
## [method JavaScriptBridge.create_callback] does not retain its reference; a dropped one leaves JS calling freed memory.
static var _callbacks: Dictionary = {}

static var _sync_guard_installed: bool = false
static var _unload_flush_installed: bool = false
static var _sync_failures_seen: int = 0


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


## Asks for the emulated filesystem to be flushed to IndexedDB; no-op off-web. Returns at once.
## On web [code]user://[/code] is an in-memory mirror persisted asynchronously, so a tab closed before the flush loses writes.
## dot-cloud calls it after each committed object, not once at the end.
## The engine's own sync can fail (a file renamed or removed between its listing and its store) and only prints to the console; a failure is counted here and logged at WARN on the next call. Use [method flush_filesystem] where the last write must land.
static func sync_filesystem() -> void:
	var b := bridge()
	if b == null:
		return
	_install_sync_guard()
	_install_unload_flush()
	_report_sync_failures()
	if b.has_method("force_fs_sync"):
		b.call("force_fs_sync")


## How many times the engine reported that a save to IndexedDB failed; 0 off-web.
static func sync_failures() -> int:
	if not _install_sync_guard():
		return 0
	var n: Variant = eval("window.__dotFsSyncFailures|0", true)
	return int(n) if n != null else 0


## Syncs, waits, and syncs again while the engine reports a failed save, up to [param attempts] times.
## The engine's callback is not visible, so the wait is a fixed [param settle_s] per attempt. Fails with [code]CODE_IO[/code] if the last attempt still reported a failure, and succeeds off-web.
static func flush_filesystem(tree: SceneTree, attempts: int = 3, settle_s: float = 1.0) -> DotResult:
	if not available() or tree == null:
		return DotResult.success(true)
	for attempt in maxi(attempts, 1):
		var before := sync_failures()
		sync_filesystem()
		await tree.create_timer(settle_s).timeout
		if sync_failures() == before:
			return DotResult.success(true)
		DotLog.warn(SYNC_CHANNEL, "browser storage save failed; trying again", {"attempt": attempt + 1, "of": attempts})
	return DotResult.fail(DotError.CODE_IO, "The browser would not save user:// to IndexedDB.")


## True when [param current] failures is more than the [param seen] count: the one comparison [method _report_sync_failures] makes.
static func has_new_sync_failures(current: int, seen: int) -> bool:
	return current > seen


## Wraps console.error once so the engine's "Failed to save IDB file system" line is also counted.
static func _install_sync_guard() -> bool:
	if _sync_guard_installed:
		return true
	if not available():
		return false
	eval("""if (!window.__dotFsGuard) { window.__dotFsGuard = true; window.__dotFsSyncFailures = 0;
		const orig = console.error; console.error = function () {
			if (arguments.length && String(arguments[0]).indexOf('Failed to save IDB file system') >= 0) window.__dotFsSyncFailures++;
			return orig.apply(console, arguments); }; }""", true)
	_sync_guard_installed = true
	return true


## Starts one more IndexedDB save when the page is hidden or unloading, so a tab closed mid-sync loses less.
## Installed by the first [method sync_filesystem]; a browser may still cut the save short, so a caller that must not lose a write uses [method flush_filesystem].
static func _install_unload_flush() -> void:
	if _unload_flush_installed:
		return
	var win: Variant = get_global("window")
	if win == null:
		return
	var on_hide := func(_args: Array) -> void:
		var b := bridge()
		if b != null and b.has_method("force_fs_sync"):
			b.call("force_fs_sync")
	var on_visibility := func(_args: Array) -> void:
		if not is_page_visible():
			on_hide.call(_args)
	var hide_cb: Variant = create_callback("dot_core.unload_flush", on_hide)
	var vis_cb: Variant = create_callback("dot_core.unload_flush_visibility", on_visibility)
	if hide_cb == null or vis_cb == null:
		return
	win.addEventListener("pagehide", hide_cb)
	win.addEventListener("beforeunload", hide_cb)
	win.addEventListener("visibilitychange", vis_cb)
	_unload_flush_installed = true


static func _report_sync_failures() -> void:
	var now := sync_failures()
	if has_new_sync_failures(now, _sync_failures_seen):
		DotLog.warn(SYNC_CHANNEL, "browser storage save failed; a later sync rewrites what it missed", {"new": now - _sync_failures_seen, "total": now})
	_sync_failures_seen = now


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
