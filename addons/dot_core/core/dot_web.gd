class_name DotWeb
extends RefCounted

## Access to the browser from GDScript, safely callable on every platform.
##
## [b]Why every call here goes through [method Engine.get_singleton] rather than
## naming [code]JavaScriptBridge[/code] directly.[/b] That singleton is only
## registered in web builds. A desktop build that mentions the identifier fails
## to parse the script, which would make every file touching it web-only —
## including files that merely want to ask "am I in a browser?". Resolving it
## dynamically costs a dictionary lookup and keeps the whole codebase compiling
## on one target.
##
## Everything here degrades to a no-op or a failed [DotResult] off-web, so
## callers can use it unguarded.

const CHANNEL := "web"

static var _bridge: Object = null
static var _bridge_looked_up: bool = false

## Callbacks handed to JS are kept alive here.
##
## [method JavaScriptBridge.create_callback] returns a reference the engine does
## NOT retain — if GDScript drops the last reference, the JS side is left
## calling into freed memory. Anything long-lived (a fetch completion, a
## visibility listener) must be rooted, so it goes in here keyed by name.
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
##
## [b]Prefer this to [method eval] for reading, and on a hardened page it is the
## only thing that works.[/b] [method eval] is a JavaScript `eval`, so a
## Content-Security-Policy that does not grant `'unsafe-eval'` refuses it — and
## that is the CORRECT policy for a page hosting a game, which needs
## `'wasm-unsafe-eval'` to compile WebAssembly and nothing more. Godot catches
## the `EvalError` and hands back null, so every read through [method eval] on
## such a page returns "nothing is there" rather than "I was not allowed to
## look": a silent, total failure that looks exactly like an empty page.
##
## Returns a [JavaScriptObject] for an object, or null when the global is absent
## (and for a primitive — `get_interface` resolves `window[name]` and wraps only
## objects, so a boolean or a string global cannot be read this way; park what
## the game needs to read on an OBJECT).
static func get_global(name: String) -> Variant:
	var b := bridge()
	if b == null:
		return null

	return b.call("get_interface", name)


## Evaluates JavaScript and returns its value.
##
## [b]Requires `'unsafe-eval'` in the page's CSP.[/b] See [method get_global],
## which does not, and which is what a reader should reach for first.
##
## Only values JS-to-Godot conversion covers come back: numbers, strings,
## booleans and null. Objects and arrays arrive as null, so anything structured
## must be [code]JSON.stringify[/code]-ed on the JS side and parsed here — see
## [method eval_json].
##
## [param use_global_scope] runs the code at global scope instead of inside a
## function body, which is what you want for declaring things that must outlive
## the call.
static func eval(code: String, use_global_scope: bool = false) -> Variant:
	var b := bridge()
	if b == null:
		return null
	return b.call("eval", code, use_global_scope)


## Evaluates JavaScript expected to produce a JSON string, and parses it.
##
## The standard way to get a structured answer out of the browser. Returns a
## failed [DotResult] rather than null-and-a-warning so the caller can tell
## "the browser said no" from "the browser said null".
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
##
## [param name] identifies the callback for lifetime purposes: registering the
## same name twice replaces the first. Returns null off-web.
static func create_callback(name: String, callable: Callable) -> Variant:
	var b := bridge()
	if b == null:
		return null

	var cb: Variant = b.call("create_callback", callable)
	_callbacks[name] = cb
	return cb


static func release_callback(name: String) -> void:
	_callbacks.erase(name)


## Flushes the emulated filesystem to IndexedDB.
##
## [b]The single most important call in this file.[/b] On web, [code]user://[/code]
## is an in-memory IDBFS mirror. Writes land in memory immediately and are
## persisted asynchronously; a tab closed before the flush completes loses them.
## Godot syncs on its own schedule, which is fine for a settings file and not
## fine for a 400 MB content cache the player just waited to download.
##
## dot-cloud therefore calls this after each object is committed to the store,
## not once at the end — a sync that never happens because the player closed the
## tab mid-download costs the whole cache, and re-downloading is exactly what
## the cache exists to prevent.
##
## No-op off-web.
static func sync_filesystem() -> void:
	var b := bridge()
	if b == null:
		return
	if b.has_method("force_fs_sync"):
		b.call("force_fs_sync")


## Best-effort storage quota, as [code]{"usage": bytes, "quota": bytes}[/code].
##
## Uses [code]navigator.storage.estimate()[/code], which is a Promise, so this
## is [code]await[/code]-ed via a rooted callback. Returns a failed result when
## the API is missing (older Safari) — callers must treat "unknown quota" as a
## normal case and fall back to a configured cache ceiling rather than assuming
## unlimited space.
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

	# Park the result on a global the poll below reads. Awaiting a JS Promise
	# from GDScript has no direct bridge, so we start it, then poll — the
	# estimate resolves in microseconds and this costs a handful of frames at
	# worst.
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


## Asks the browser to make storage persistent so it is not evicted under
## pressure.
##
## Without this, a browser low on disk may clear the origin's IndexedDB — taking
## the content cache with it. Chrome grants it silently for installed or
## engaged origins; Firefox prompts; Safari ignores it. Always call, never rely
## on it: the cache must survive being wiped, which it does, by re-downloading.
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
##
## Needed to build same-origin content URLs, which is the one way to sidestep
## CORS entirely.
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
##
## Decides whether a WebSocket connection must use [code]wss://[/code]: a secure
## page cannot open an insecure socket, and the failure is a console message the
## player never sees.
static func is_secure_context() -> bool:
	if not available():
		return false
	var v: Variant = eval("window.isSecureContext ? 1 : 0", true)
	return int(v if v != null else 0) == 1


## Whether the page itself was served over HTTPS.
##
## [b]Not the same question as [method is_secure_context], and confusing the two breaks
## every local test.[/b] A browser treats [code]http://localhost[/code] and
## [code]http://127.0.0.1[/code] as trustworthy origins, so [code]isSecureContext[/code]
## is [code]true[/code] on a plain HTTP page served from either — while mixed-content
## blocking, which is the rule that actually decides whether a [code]ws://[/code] socket
## may be opened, exempts exactly those origins.
##
## So a caller asking "may I open an insecure socket" wants this, not the other one. Asking
## the other one refuses every `ws://` connection from a development page, upgrades it to
## `wss://`, and fails against a server that has no certificate — which is every server
## anybody tests against locally.
static func is_https_page() -> bool:
	if not available():
		return false

	var v: Variant = eval("window.location.protocol === 'https:' ? 1 : 0", true)
	return int(v if v != null else 0) == 1
