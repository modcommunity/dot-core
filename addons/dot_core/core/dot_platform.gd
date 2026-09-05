class_name DotPlatform
extends RefCounted

## What this build can actually do, asked once and cached.
##
## The dot-* family targets desktop, mobile and the browser from one codebase,
## and the browser is missing things the other targets take for granted: no UDP
## (so no ENet), no threads unless the export template was built for them, no
## raw [HTTPClient], a filesystem that is an IndexedDB mirror needing explicit
## flushes, and a storage quota the user can refuse.
##
## Every one of those differences is a branch somewhere. Centralising them here
## means the branches read as capability questions
## ([code]DotPlatform.has_threads()[/code]) rather than platform sniffing
## ([code]OS.get_name() == "Web"[/code]) — which matters because the mapping is
## not one-to-one: a threads-enabled web template has threads, and a
## single-threaded desktop build does not.

enum Kind {
	UNKNOWN,
	WINDOWS,
	MACOS,
	LINUX,
	ANDROID,
	IOS,
	WEB,
}

## Storage families, which is the distinction the content cache cares about.
enum Storage {
	## A real filesystem with room to spare. Desktop.
	NATIVE,
	## A real filesystem inside an app sandbox that the OS may reclaim. Mobile.
	SANDBOXED,
	## IndexedDB behind an emulated FS: needs explicit flushes, has a quota,
	## and can be cleared by the browser without warning.
	BROWSER,
}

static var _kind: int = -1
static var _storage: int = -1


static func kind() -> int:
	if _kind >= 0:
		return _kind

	# has_feature() is preferred over get_name() because it also reflects
	# how the template was built.
	if OS.has_feature("web"):
		_kind = Kind.WEB
	elif OS.has_feature("android"):
		_kind = Kind.ANDROID
	elif OS.has_feature("ios"):
		_kind = Kind.IOS
	elif OS.has_feature("windows"):
		_kind = Kind.WINDOWS
	elif OS.has_feature("macos"):
		_kind = Kind.MACOS
	elif OS.has_feature("linux") or OS.has_feature("linuxbsd"):
		_kind = Kind.LINUX
	else:
		_kind = Kind.UNKNOWN

	return _kind


static func kind_name() -> String:
	match kind():
		Kind.WINDOWS: return "windows"
		Kind.MACOS: return "macos"
		Kind.LINUX: return "linux"
		Kind.ANDROID: return "android"
		Kind.IOS: return "ios"
		Kind.WEB: return "web"
		_: return "unknown"


## The platform label the website-city backbone's app API accepts.
##
## Its `ClientInfoSchema.platform` enum has no `web` member, so a browser build
## reports `unknown` rather than sending a value that fails validation.
static func backbone_platform() -> String:
	match kind():
		Kind.WINDOWS: return "windows"
		Kind.MACOS: return "macos"
		Kind.LINUX: return "linux"
		Kind.ANDROID: return "android"
		Kind.IOS: return "ios"
		_: return "unknown"


static func is_web() -> bool:
	return kind() == Kind.WEB


static func is_mobile() -> bool:
	var k := kind()
	return k == Kind.ANDROID or k == Kind.IOS


static func is_desktop() -> bool:
	var k := kind()
	return k == Kind.WINDOWS or k == Kind.MACOS or k == Kind.LINUX


## True when this build runs without a display server.
##
## The distinction a dedicated server cares about, and it is not the same as
## "is a server": a listen server has a window, a headless test run does not.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


static func storage() -> int:
	if _storage >= 0:
		return _storage

	if is_web():
		_storage = Storage.BROWSER
	elif is_mobile():
		_storage = Storage.SANDBOXED
	else:
		_storage = Storage.NATIVE

	return _storage


# --- Capabilities ----------------------------------------------------------

## Whether [Thread] does real work.
##
## On web this is false unless the export template was built with thread
## support, and calling into threads anyway does not error — it silently runs
## on the main thread and janks. Everything expensive in dot-* is written to
## work either way; this only decides whether it gets a worker.
static func has_threads() -> bool:
	# The "threads" feature tag is set by the export template when it was built
	# with thread support. Godot 4 has no OS.can_use_threads(); the tag is the
	# only honest signal, and it is absent exactly on single-threaded web builds.
	if is_web():
		return OS.has_feature("threads")
	return true


## Whether UDP sockets exist, and therefore whether ENet can be used.
##
## The browser sandbox has no UDP at all: [ENetMultiplayerPeer] is not even
## compiled into the web template, so this is also a "does the class exist"
## question, not just a policy one.
static func has_udp() -> bool:
	if is_web():
		return false
	return ClassDB.class_exists("ENetMultiplayerPeer")


static func has_websocket() -> bool:
	# Available on every export target, which is what makes it the only
	# transport that can serve desktop and browser clients from one listener.
	return ClassDB.class_exists("WebSocketMultiplayerPeer")


static func has_webrtc() -> bool:
	# WebRTC ships as an optional module/GDExtension rather than in the
	# standard templates, so presence must be probed rather than assumed.
	return ClassDB.class_exists("WebRTCMultiplayerPeer")


## Whether raw [HTTPClient] works.
##
## False on web: only [HTTPRequest] does, because the browser forces requests
## through `fetch()`. Anything in dot-* that talks HTTP therefore uses
## [HTTPRequest] unconditionally rather than branching — this exists to explain
## why, and for callers who genuinely need streaming sockets.
static func has_raw_http_client() -> bool:
	return not is_web()


## Whether HTTP range requests can be used to resume a partial download.
##
## Technically a server-side question, but on web the answer is also gated by
## CORS exposing `Accept-Ranges`, so treat it as a capability and fall back to
## restarting the transfer when it turns out to be false.
static func can_resume_downloads() -> bool:
	return true


## Whether a resource pack can be mounted from user:// at runtime.
##
## True everywhere, including web — [code]user://[/code] is backed by IndexedDB
## there and [method ProjectSettings.load_resource_pack] reads it happily. What
## is NOT possible on any platform is *unmounting*; see [DotPlatform.can_unmount_packs].
static func can_mount_packs() -> bool:
	return true


## Whether a mounted resource pack can be removed again. Always false.
##
## Godot has no [code]unload_resource_pack[/code]. Once a PCK is mounted its
## file table stays merged into the virtual filesystem for the process
## lifetime. This is the single hardest constraint on hot-swapping content and
## the reason dot-cloud namespaces every game under its own path prefix instead
## of unmounting; see dot-cloud's CLAUDE.md.
static func can_unmount_packs() -> bool:
	return false


## Whether the process can restart itself to get a clean filesystem.
##
## The escape hatch for the constraint above. Desktop can re-exec; a browser
## tab can reload; mobile cannot do either reliably.
static func can_self_restart() -> bool:
	return is_desktop() or is_web()


## Whether this build can open a listening socket at all.
##
## A browser tab cannot, which is what makes "host a server" a desktop/mobile
## affordance and leaves web builds as clients only.
static func can_listen() -> bool:
	return not is_web()


## Whether [FileAccess] encrypted files are usable for the token store.
##
## Works everywhere the engine has a filesystem. Note that on web the key
## material lives in the same origin as the ciphertext, so this is obfuscation
## against casual inspection rather than real at-rest protection — dot-auth says
## so where it matters.
static func has_encrypted_files() -> bool:
	return true


# --- Reporting -------------------------------------------------------------

## A flat snapshot for logs, `status` output and bug reports.
static func describe() -> Dictionary:
	return {
		"kind": kind_name(),
		"os": OS.get_name(),
		"model": OS.get_model_name(),
		"distro": OS.get_distribution_name(),
		"debug": OS.is_debug_build(),
		"headless": is_headless(),
		"display_server": DisplayServer.get_name(),
		"engine": "%d.%d.%d" % [
			Engine.get_version_info()["major"],
			Engine.get_version_info()["minor"],
			Engine.get_version_info()["patch"],
		],
		"threads": has_threads(),
		"processors": OS.get_processor_count(),
		"udp": has_udp(),
		"websocket": has_websocket(),
		"webrtc": has_webrtc(),
		"raw_http": has_raw_http_client(),
		"can_listen": can_listen(),
		"can_mount_packs": can_mount_packs(),
		"can_unmount_packs": can_unmount_packs(),
		"storage": ["native", "sandboxed", "browser"][storage()],
	}


static func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append("%-16s %s" % [k, str(d[k])])
	return out
