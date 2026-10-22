class_name DotCfgLegacy
extends RefCounted

## Migration shim: a config file that moved is still read from its old path, with one WARN.

const CHANNEL := "cfg"
## After this date (YYYY-MM-DD) the old path is ignored and one ERROR names it.
const REMOVE_AFTER := "2026-12-31"

## Old paths already reported, so a reload does not repeat the line.
static var _warned: Dictionary = {}
## Replaces the system date in tests; empty uses the clock.
static var today_override: String = ""


## The path to read: [param new_path] when it exists, else [param old_path] (warned once) while the
## shim lasts, else "". The files are never merged: when both exist the new one wins whole.
static func find(old_path: String, new_path: String) -> String:
	var old_there := old_path != "" and FileAccess.file_exists(old_path)
	var new_there := new_path != "" and FileAccess.file_exists(new_path)
	if not old_there:
		return new_path if new_there else ""
	var expired := _today() > REMOVE_AFTER
	if new_there:
		_report(old_path, "ignored, %s wins; delete the old file" % new_path, new_path, expired)
		return new_path
	if expired:
		_report(old_path, "no longer read; move it to %s" % new_path, new_path, true)
		return ""
	_report(old_path, "still read; move it to %s before %s" % [new_path, REMOVE_AFTER], new_path, false)
	return old_path


## How many distinct old paths have been reported (for tests and `describe`).
static func warned_count() -> int:
	return _warned.size()


## Forgets what was reported.
static func reset() -> void:
	_warned.clear()
	today_override = ""


static func _today() -> String:
	return today_override if today_override != "" else Time.get_date_string_from_system()


static func _report(old_path: String, what: String, new_path: String, is_error: bool) -> void:
	if _warned.has(old_path):
		return
	_warned[old_path] = true
	var fields := {"old": old_path, "new": new_path, "remove_after": REMOVE_AFTER}
	var msg := "legacy config file %s: %s" % [old_path, what]
	if is_error:
		DotLog.error(CHANNEL, msg, fields)
	else:
		DotLog.warn(CHANNEL, msg, fields)
