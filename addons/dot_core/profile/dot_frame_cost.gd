class_name DotFrameCost
extends RefCounted

## What each system cost this frame, reported by the systems, so a slow frame is pinned on one. Off by default and free while off.
## [code]var t := DotFrameCost.now()[/code] (0 while disabled), then [code]DotFrameCost.add(&"navigation", t, "note")[/code].
## One reader drains it per frame with [method take] (DotHitchLog does); only plain values are kept, since a script object in a static aborts teardown.

## Set by the profiler; systems only ever call [method now] and [method add].
static var enabled := false
## Also keep every span's start and end, so a profiler can rebuild who ran inside whom ([method take_events]).
static var trace := false

static var _rows := {}
static var _what := {}
static var _queries := {}
## Spans as start, end, name id triples; ids index [member _names].
static var _events := PackedInt64Array()
static var _ids := {}
static var _names: Array[StringName] = []
static var _qnames := {}


## The start stamp for [method add]: the time in microseconds, or 0 while disabled.
static func now() -> int:
	return Time.get_ticks_usec() if enabled else 0


## Charges the time since [param since_usec] to [param system]; [param what] names the worst call.
static func add(system: StringName, since_usec: int, what: String = "") -> void:
	if not enabled or since_usec <= 0:
		return
	add_usec(system, Time.get_ticks_usec() - since_usec, what)


## Charges [param usec] already measured by the caller to [param system]; a traced span is taken to end now.
static func add_usec(system: StringName, usec: int, what: String = "") -> void:
	if not enabled:
		return
	if trace:
		span(system, Time.get_ticks_usec() - usec, usec)
	var row: PackedInt64Array = _rows.get(system, PackedInt64Array([0, 0, 0]))
	row[0] += usec
	row[1] += 1
	if usec >= row[2]:
		row[2] = usec
		if not what.is_empty():
			_what[system] = what
	_rows[system] = row


## Records a span of [param usec] from [param start_usec] under [param name] while tracing, without charging a system.
static func span(name: StringName, start_usec: int, usec: int) -> void:
	if not trace:
		return
	var id: int = _ids.get(name, -1)
	if id < 0:
		id = _names.size()
		_ids[name] = id
		_names.append(name)
	var _a := _events.append(start_usec)
	var _b := _events.append(start_usec + usec)
	var _c := _events.append(id)


## Counts one physics query of [param kind] (cast_motion, intersect_ray, ...) made by [param system], timed from
## [param since_usec]; [param count] is for a batch measured as one call. Traced as a span named "q.<kind>".
static func add_query(system: StringName, kind: StringName, since_usec: int, count: int = 1) -> void:
	if not enabled or since_usec <= 0:
		return
	var usec := Time.get_ticks_usec() - since_usec
	var key := system if system != &"" else &"unattributed"
	var by_kind: Dictionary = _queries.get(key, {})
	var row: PackedInt64Array = by_kind.get(kind, PackedInt64Array([0, 0, 0]))
	row[0] += usec
	row[1] += count
	row[2] = maxi(row[2], usec)
	by_kind[kind] = row
	_queries[key] = by_kind
	if trace:
		var q: StringName = _qnames.get(kind, &"")
		if q == &"":
			q = StringName("q." + kind)
			_qnames[kind] = q
		span(q, since_usec, usec)


## This frame's queries as {system: {kind: {ms, calls, worst_ms}}}, and clears them.
static func take_queries() -> Dictionary:
	var out := {}
	for system: StringName in _queries:
		var kinds := {}
		var by_kind: Dictionary = _queries[system]
		for kind: StringName in by_kind:
			var row: PackedInt64Array = by_kind[kind]
			kinds[kind] = {"ms": row[0] / 1000.0, "calls": row[1], "worst_ms": row[2] / 1000.0}
		out[system] = kinds
	_queries.clear()
	return out


## This frame's spans as {events: start, end, name id triples in microseconds, names: every name by id}, and clears them.
## [code]names[/code] only grows, so ids stay valid across frames.
static func take_events() -> Dictionary:
	var out := {"events": _events, "names": _names}
	_events = PackedInt64Array()
	return out


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
	trace = false
	_rows.clear()
	_what.clear()
	_queries.clear()
	_events = PackedInt64Array()


static func describe() -> String:
	return "DotFrameCost enabled=%s trace=%s pending=%d events=%d" % [enabled, trace, _rows.size(), _events.size() / 3]
