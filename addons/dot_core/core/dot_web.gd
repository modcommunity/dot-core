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
## Never evaluate JavaScript instead: the game origin's CSP has no 'unsafe-eval' and the engine returns null, indistinguishable from an empty page.
## Returns null for an absent global and for a primitive (only objects are wrapped); park values on an object.
static func get_global(name: String) -> Variant:
	var b := bridge()
	if b == null:
		return null

	return b.call("get_interface", name)


## The page-side helper from web/dot_web.js (window.dotWeb), or null when the page does not load it.
## Nothing here evaluates a string: the game origin's CSP has no 'unsafe-eval', so every browser call is a named function there.
static func page() -> Variant:
	return get_global("dotWeb")


static func _page_or_fail() -> DotResult:
	if not available():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "Not running in a browser.")
	var p: Variant = page()
	if p == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "The page does not load dot_web.js.")
	return DotResult.success(p)


## Posts a JSON-encoded [param payload] to the embedding page (window.parent).
static func post_to_parent(payload: Variant) -> DotResult:
	var r := _page_or_fail()
	if not r.ok:
		return r
	var sent: Variant = r.value.postToParent(JSON.stringify(payload))
	if sent == true:
		return DotResult.success(true)
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "No embedding page took the message.")


## Locks Escape and other browser keys while fullscreen. The page does it by itself on fullscreenchange; this is for a caller that knows better.
static func lock_keyboard() -> DotResult:
	var r := _page_or_fail()
	if not r.ok:
		return r
	var locked: Variant = r.value.lockKeyboard()
	if locked == true:
		return DotResult.success(true)
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "navigator.keyboard.lock is unavailable.")


## Installs nothing (the page script did); reports whether the leave-site guard exists to arm.
static func has_tab_guard() -> bool:
	return get_global("__dotTabGuard") != null


## Arms or disarms the browser's leave-site prompt.
static func set_tab_guard_armed(armed: bool) -> DotResult:
	var g: Variant = get_global("__dotTabGuard")
	if g == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "The page has no leave-site guard.")
	g.armed = armed
	return DotResult.success(armed)


## Hands [param text] to the browser as a download named [param filename].
static func download_text(text: String, filename: String) -> DotResult:
	var r := _page_or_fail()
	if not r.ok:
		return r
	r.value.downloadText(text, filename)
	return DotResult.success(true)


## True when the browser reports Save-Data or a cellular connection; false when it cannot say.
static func is_metered() -> bool:
	var p: Variant = page()
	if p == null:
		return false
	return p.isMetered() == true


## Parks [param text] at window.dotWeb.published[key], for a harness to read. A no-op without the page script.
static func publish(key: String, text: String) -> void:
	var p: Variant = page()
	if p != null:
		p.publish(key, text)


## Reloads the page; no-op off-web. Not named reload: DotWeb.reload() would call Script.reload() instead.
static func reload_page() -> void:
	var loc: Variant = get_global("location")
	if loc != null:
		loc.reload()


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
## [code]user://[/code] is an in-memory mirror persisted asynchronously, so a tab closed before the flush loses writes; dot-cloud calls it after each committed object.
## The engine's sync only prints on failure; a failure is counted here and logged at WARN on the next call. Use [method flush_filesystem] where the last write must land.
static func sync_filesystem() -> void:
	var b := bridge()
	if b == null:
		return
	_install_unload_flush()
	_report_sync_failures()
	if b.has_method("force_fs_sync"):
		b.call("force_fs_sync")


## How many times the engine reported that a save to IndexedDB failed; 0 off-web.
static func sync_failures() -> int:
	var p: Variant = page()
	if p == null:
		return 0
	var n: Variant = p.fsSyncFailures
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
	var r := _page_or_fail()
	if not r.ok:
		return r
	var p: Variant = r.value
	if p.startStorageEstimate() != true:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "navigator.storage.estimate is unavailable.")

	# A JS Promise cannot be awaited from GDScript: the page parks the result on a property and it resolves in microseconds.
	var loop := Engine.get_main_loop()
	for _i in range(120):
		var raw: Variant = p.storageEstimate
		if raw != null and str(raw) != "":
			var parsed: Variant = JSON.parse_string(str(raw))
			if parsed is Dictionary:
				return DotResult.success(parsed)
			break
		if loop is SceneTree:
			await (loop as SceneTree).process_frame
		else:
			break

	return DotResult.fail(DotError.CODE_TIMEOUT, "Storage estimate did not resolve.")


## Whether [method fetch_bytes] can run: a browser whose page loads a dot_web.js with fetchStart.
static func can_fetch_bytes() -> bool:
	var b := bridge()
	if b == null or not b.has_method("js_buffer_to_packed_byte_array"):
		return false
	var p: Variant = page()
	return p != null and p.fetchStart != null


## A GET read whole by the browser, as [code]{status, headers (PackedStringArray "k: v"), body}[/code].
## [HTTPRequest] on web reads one stream chunk per frame, so a large body arrives at chunk x fps; this does not.
## Fails CODE_UNSUPPORTED when [method can_fetch_bytes] is false, CODE_INVALID over [param max_bytes] (0 = none).
static func fetch_bytes(url: String, header_list: PackedStringArray, timeout_s: float, max_bytes: int = 0) -> DotResult:
	if not can_fetch_bytes():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "The page cannot fetch a whole body.")
	var p: Variant = page()
	var headers := {}
	for line in header_list:
		var idx := line.find(":")
		if idx > 0:
			headers[line.substr(0, idx).strip_edges()] = line.substr(idx + 1).strip_edges()
	var timeout_ms := int(maxf(timeout_s, 0.0) * 1000.0)
	var id: Variant = p.fetchStart(url, JSON.stringify(headers), timeout_ms, max_bytes)
	if id == null or int(id) <= 0:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "fetch is unavailable.")

	# The page parks the outcome and GDScript polls once a frame, as in estimate_storage.
	var loop := Engine.get_main_loop()
	var started := Time.get_ticks_msec()
	var raw := ""
	while true:
		var polled: Variant = p.fetchPoll(id)
		raw = "" if polled == null else str(polled)
		if raw != "":
			break
		var stuck := timeout_ms > 0 and Time.get_ticks_msec() - started > timeout_ms + 5000
		if stuck or not (loop is SceneTree):
			p.fetchDrop(id)
			return DotResult.fail(DotError.CODE_TIMEOUT, "The browser fetch did not finish.", url)
		await (loop as SceneTree).process_frame

	var buf: Variant = p.fetchTake(id)
	var parsed: Variant = JSON.parse_string(raw)
	var info: Dictionary = parsed if parsed is Dictionary else {"error": "unknown"}
	var error := str(info.get("error", ""))
	if error == "timeout":
		return DotResult.fail(DotError.CODE_TIMEOUT, "The browser fetch timed out.", url)
	if error == "too_large":
		return DotResult.fail(DotError.CODE_INVALID, "Response is larger than the caller allows.",
			"%d > %d bytes" % [int(info.get("size", 0)), max_bytes])
	if error != "" or buf == null:
		return DotResult.fail(DotError.CODE_NETWORK, "The browser fetch failed.", str(info.get("detail", error)))

	var body: PackedByteArray = bridge().call("js_buffer_to_packed_byte_array", buf)
	var lines := PackedStringArray()
	var listed: Variant = info.get("headers", [])
	if listed is Array:
		for h in listed:
			lines.append(str(h))
	return DotResult.success({"status": int(info.get("status", 0)), "headers": lines, "body": body})


## Asks the browser to make storage persistent so it is not evicted under pressure.
## Chrome grants silently, Firefox prompts, Safari ignores: always call, never rely on it.
static func request_persistent_storage() -> void:
	var p: Variant = page()
	if p != null:
		p.requestPersistentStorage()


## The page's origin, e.g. [code]https://example.com[/code]. Empty off-web.
## Needed for same-origin content URLs, which sidestep CORS.
static func origin() -> String:
	if not available():
		return ""
	var loc: Variant = get_global("location")
	if loc == null:
		return ""
	var v: Variant = loc.origin
	return str(v) if v != null else ""


## The page's path, e.g. [code]/game/app/b123/embed.html[/code]. Empty off-web.
static func pathname() -> String:
	var loc: Variant = get_global("location")
	if loc == null:
		return ""
	var v: Variant = loc.pathname
	return str(v) if v != null else ""


## Query parameter from the page URL, for passing a server address into an
## embedded web build without rebuilding it.
static func query_param(key: String) -> String:
	if not available():
		return ""
	var loc: Variant = get_global("location")
	if loc == null:
		return ""
	var search: Variant = loc.search
	if search == null:
		return ""
	return query_param_from(str(search), key)


## The value of [param key] in a [code]?a=1&b=2[/code] string, percent-decoded; empty when absent.
static func query_param_from(search: String, key: String) -> String:
	for pair in search.trim_prefix("?").split("&", false):
		var kv := pair.split("=", true, 1)
		if kv[0].uri_decode() == key:
			return kv[1].replace("+", " ").uri_decode() if kv.size() > 1 else ""
	return ""


## Whether the page is served over HTTPS.
## Decides whether a WebSocket must use [code]wss://[/code]: a secure page cannot open an insecure socket.
static func is_secure_context() -> bool:
	if not available():
		return false
	var win: Variant = get_global("window")
	if win == null:
		return false
	return win.isSecureContext == true


## Whether the page itself was served over HTTPS.
## Not [method is_secure_context]: browsers treat http://localhost as a secure context, but mixed-content blocking
## (what decides whether [code]ws://[/code] may open) exempts exactly those origins; the wrong one breaks local tests.
static func is_https_page() -> bool:
	if not available():
		return false

	var loc: Variant = get_global("location")
	if loc == null:
		return false
	return str(loc.protocol) == "https:"


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
