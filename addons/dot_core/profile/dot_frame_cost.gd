class_name DotFrameCost
extends RefCounted

## What each system cost this frame, reported by the systems, so a slow frame is pinned on one. Off by default and free while off.
## [code]var t := DotFrameCost.now()[/code] (0 while disabled), then [code]DotFrameCost.add(&"navigation", t, "note")[/code].
## One reader drains it per frame with [method take] (DotHitchLog does); only plain values are kept, since a script object in a static aborts teardown.

## Set by the profiler; systems only ever call [method now] and [method add].
static var enabled := false

static var _rows := {}
static var _what := {}


## The start stamp for [method add]: the time in microseconds, or 0 while disabled.
static func now() -> int:
	return Time.get_ticks_usec() if enabled else 0


## Charges the time since [param since_usec] to [param system]; [param what] names the worst call.
static func add(system: StringName, since_usec: int, what: String = "") -> void:
	if not enabled or since_usec <= 0:
		return
	add_usec(system, Time.get_ticks_usec() - since_usec, what)


## Charges [param usec] already measured by the caller to [param system].
static func add_usec(system: StringName, usec: int, what: String = "") -> void:
	if not enabled:
		return
	var row: PackedInt64Array = _rows.get(system, PackedInt64Array([0, 0, 0]))
	row[0] += usec
	row[1] += 1
	if usec >= row[2]:
		row[2] = usec
		if not what.is_empty():
			_what[system] = what
	_rows[system] = row


## This frame's costs as {system: {ms, calls, worst_ms, what}}, and clears them for the next.
static func take() -> Dictionary:
	var out := {}
	for system: StringName in _rows:
		var row: PackedInt64Array = _rows[system]
		out[system] = {"ms": row[0] / 1000.0, "calls": row[1], "worst_ms": row[2] / 1000.0,
			"what": _what.get(system, "")}
	_rows.clear()
	_what.clear()
	return out


## Drops anything reported and turns reporting off.
static func reset() -> void:
	enabled = false
	_rows.clear()
	_what.clear()


static func describe() -> String:
	return "DotFrameCost enabled=%s pending=%d" % [enabled, _rows.size()]
