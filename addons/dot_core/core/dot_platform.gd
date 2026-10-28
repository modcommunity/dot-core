class_name DotPlatform
extends RefCounted

## What this build can actually do, asked once and cached.
## The browser lacks UDP, threads (unless the template has them), [HTTPClient] and a plain filesystem; callers ask
## capability questions ([code]DotPlatform.has_threads()[/code]), not [code]OS.get_name() == "Web"[/code], since the mapping is not one-to-one.

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
## Its enum has no [code]web[/code], so a browser build reports [code]unknown[/code].
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
## Not "is a server": a listen server has a window, a headless test run does not.
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



## Whether [Thread] does real work.
## On web it is false without a threads template, and threads then silently run on the main thread and jank.
static func has_threads() -> bool:
	# The "threads" feature tag is set by the export template when it was built
	# with thread support. Godot 4 has no OS.can_use_threads(); the tag is the
	# only honest signal, and it is absent exactly on single-threaded web builds.
	if is_web():
		return OS.has_feature("threads")
	return true


## Whether UDP sockets exist, and therefore whether ENet can be used.
## The web template has no UDP and does not compile [ENetMultiplayerPeer], so it is also a "does the class exist" question.
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
## False on web, where only [HTTPRequest] does (through [code]fetch()[/code]); dot-* uses [HTTPRequest] unconditionally.
static func has_raw_http_client() -> bool:
	return not is_web()


## Whether HTTP range requests can be used to resume a partial download.
## On web it also depends on CORS exposing [code]Accept-Ranges[/code]; fall back to restarting the transfer.
static func can_resume_downloads() -> bool:
	return true


## Whether a resource pack can be mounted from user:// at runtime; true everywhere, web included.
## Unmounting is the impossible part; see [method can_unmount_packs].
static func can_mount_packs() -> bool:
	return true


## Whether a mounted resource pack can be removed again. Always false.
## Godot has no [code]unload_resource_pack[/code]; dot-cloud namespaces content by path prefix instead (docs/mounting.md).
static func can_unmount_packs() -> bool:
	return false


## Whether the process can restart itself to get a clean filesystem.
## The escape hatch for [method can_unmount_packs]: desktop re-execs, a tab reloads, mobile cannot reliably.
static func can_self_restart() -> bool:
	return is_desktop() or is_web()


## Whether this build can open a listening socket at all.
## A browser tab cannot, so web builds are clients only.
static func can_listen() -> bool:
	return not is_web()


## Whether [method OS.get_unique_id] may be CALLED, never mind what it returns.
## On web and iOS the engine pushes an error before returning the empty string, so checking the result for emptiness is too late.
static func has_unique_id() -> bool:
	return not (is_web() or kind() == Kind.IOS)


## The machine's own identifier, or the empty string where there is none. Never errors.
## Callers needing a stable id generate and store one; see [code]DotClientLink._device_id[/code].
static func unique_id() -> String:
	return OS.get_unique_id() if has_unique_id() else ""


## Whether [FileAccess] encrypted files are usable for the token store.
## On web the key lives beside the ciphertext, so this is obfuscation, not at-rest protection.
static func has_encrypted_files() -> bool:
	return true



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
		"unique_id": has_unique_id(),
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
