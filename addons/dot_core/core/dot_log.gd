class_name DotLog
extends RefCounted

## Levelled, channelled logging with pluggable sinks: a channel (subsystem), a level and structured fields.
## Static, not an autoload, so it can be called from a [Resource], a static function or an early [method _init].
## Capture output by attaching a [DotLogSink] node or a [Callable] via [method add_sink].

## The six levels; a level is a promise to the reader, not a volume knob.
## TRACE per-frame detail; DEBUG a decision or transition; INFO what an admin keeps; WARN recoverable, someone should look;
## ERROR the operation failed; FATAL the process cannot continue.
enum Level {
		## Per-frame or per-packet detail. Off outside debugging.
		## Guard an expensive message with [method enabled]: building a dump only to drop it is the one cost a logger cannot remove.
	TRACE,

	## Decisions and state transitions. What you turn on to answer "why did it do that".
	DEBUG,

		## Things an admin would want in the log by default.
		## The default threshold: anything here is worth keeping in every log forever.
	INFO,

		## Recoverable; someone should look eventually.
		## The operation continued, possibly degraded. Not mirrored to the engine; see [member mirror_min_level].
	WARN,

		## The operation failed.
		## The caller was told; the server is still running and the next request may work.
	ERROR,

		## The process cannot continue.
		## Reserve it: it promises a shutdown follows, and there is exactly one in the family ([code]DotServer._boot_failed[/code]).
		## Sinks flush every target on one, since a buffered record is lost when the process goes.
	FATAL,

	## Never emitted. Only valid as a threshold.
	OFF,
}


## How the level is rendered in the console line.
## Tags are the default: a fixed three characters keep the message column aligned. Names suit a log parsed by eye or column.
enum LevelStyle {
	TAG,   ## [code]inf[/code], [code]WRN[/code]. Three characters, aligned.
	NAME,  ## [code]INFO[/code], [code]WARN[/code]. Padded to five.
}

const LEVEL_NAMES: Array[String] = [
	"TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL", "OFF",
]

## Short tags for the compact console format, padded to a fixed width so the
## message column lines up when you are reading a wall of them.
const LEVEL_TAGS: Array[String] = [
	"trc", "dbg", "inf", "WRN", "ERR", "FTL", "off",
]

static var _level: int = Level.INFO
static var _channel_levels: Dictionary = {}
static var _sinks: Array[Callable] = []

## Whether to also route the serious levels through [method push_warning] / [method push_error] so failures reach the Errors dock.
## Off in exported builds by default: the sinks own the log there and stderr would double.
static var mirror_to_engine: bool = OS.is_debug_build()

## The lowest level [member mirror_to_engine] mirrors.
## ERROR, not WARN: [method push_warning] adds an engine [code]at:[/code] line and a backtrace that cannot be suppressed per call,
## so an expected warning looks like a crash. Set [constant Level.WARN] while hunting a specific warning.
static var mirror_min_level: int = Level.ERROR

## Whether to print to stdout. A dedicated server wants this on; a shipped
## client usually wants only the file sink.
static var print_to_stdout: bool = true

## How [method format_line] renders the level. See [enum LevelStyle].
static var level_style: LevelStyle = LevelStyle.TAG

## Include a wall-clock timestamp. Off by default because most sinks (files,
## journald, the editor) add their own, and two timestamps per line is worse
## than none.
static var timestamps: bool = false

## Emitted for every record that passes the level filter, after the sinks run.
## Wired through a hidden singleton node so that UI can `connect` to it without
## dot-core owning an autoload; see [method signals].
static var _bus: DotLogBus = null



static func set_level(level: int) -> void:
	_level = clampi(level, Level.TRACE, Level.OFF)


static func get_level() -> int:
	return _level


## Raise or lower the threshold for one channel only.
## DEBUG globally also turns on every physics and RPC trace. [constant Level.OFF] silences a channel.
static func set_channel_level(channel: String, level: int) -> void:
	_channel_levels[channel] = clampi(level, Level.TRACE, Level.OFF)


static func clear_channel_level(channel: String) -> void:
	_channel_levels.erase(channel)


static func get_channel_level(channel: String) -> int:
	return _channel_levels.get(channel, _level)


## Parses a level from a string, for cvars and command-line flags.
## Accepts names ("debug", "WARN") and numbers ("2"). Returns -1 if unparseable.
static func parse_level(s: String) -> int:
	var t := s.strip_edges().to_upper()
	if t.is_valid_int():
		var n := t.to_int()
		return n if n >= Level.TRACE and n <= Level.OFF else -1
	var idx := LEVEL_NAMES.find(t)
	return idx


static func level_name(level: int) -> String:
	if level < 0 or level >= LEVEL_NAMES.size():
		return "?"
	return LEVEL_NAMES[level]


## The level as it appears in a console line, padded to a fixed width.
## Fixed width so the message column starts in the same place on every line.
static func level_column(level: int) -> String:
	if level < 0 or level >= LEVEL_NAMES.size():
		return "???" if level_style == LevelStyle.TAG else "?????"
	if level_style == LevelStyle.NAME:
		return "%-5s" % LEVEL_NAMES[level]
	return LEVEL_TAGS[level]



## Registers a sink. The callable receives one [Dictionary] record; see [method _emit].
## Sinks run synchronously in registration order; a blocking sink blocks the frame, so file sinks buffer ([DotLogSink]).
static func add_sink(sink: Callable) -> void:
	if not _sinks.has(sink):
		_sinks.append(sink)


static func remove_sink(sink: Callable) -> void:
	_sinks.erase(sink)


static func clear_sinks() -> void:
	_sinks.clear()


## Drops the sinks and the signal bus so a headless run exits with nothing of the log alive.
static func clear_cache() -> void:
	_sinks.clear()
	_bus = null


static func sink_count() -> int:
	return _sinks.size()


## A [DotLogBus] carrying a `record` signal, for UI that would rather connect
## than register a callable. Created on first use.
static func signals() -> DotLogBus:
	if _bus == null:
		_bus = DotLogBus.new()
	return _bus



static func trace(channel: String, message: String, fields: Dictionary = {}) -> void:
	_emit(Level.TRACE, channel, message, fields)


static func debug(channel: String, message: String, fields: Dictionary = {}) -> void:
	_emit(Level.DEBUG, channel, message, fields)


static func info(channel: String, message: String, fields: Dictionary = {}) -> void:
	_emit(Level.INFO, channel, message, fields)


static func warn(channel: String, message: String, fields: Dictionary = {}) -> void:
	_emit(Level.WARN, channel, message, fields)


static func error(channel: String, message: String, fields: Dictionary = {}) -> void:
	_emit(Level.ERROR, channel, message, fields)


static func fatal(channel: String, message: String, fields: Dictionary = {}) -> void:
	_emit(Level.FATAL, channel, message, fields)


## Logs at a level chosen at runtime.
## Code should call the six named functions (greppable); this is for levels that are data, such as a console command or a bridge.
## [constant Level.OFF] is refused: it is a threshold, not a severity.
static func at(
	level: int, channel: String, message: String, fields: Dictionary = {}
) -> void:
	if level < Level.TRACE or level >= Level.OFF:
		push_error("DotLog.at() with a level that is not one of the six: %d" % level)
		return
	_emit(level, channel, message, fields)


## Logs a [DotResult] failure, or nothing at all on success.
## [param level] matters: ERROR means a fault, and an optional subsystem not installed or an unconfigured backbone is
## configuration, so pass [constant Level.DEBUG] or [constant Level.WARN] there. [constant Level.OFF] is refused.
static func result(
	channel: String, what: String, res: DotResult, level: int = Level.ERROR
) -> void:
	if res == null or res.ok:
		return
	if level < Level.TRACE or level >= Level.OFF:
		push_error("DotLog.result() with a level that is not one of the six: %d" % level)
		level = Level.ERROR
	var fields := {"code": res.code()}
	if res.error != null:
		if res.error.detail != "":
			fields["detail"] = res.error.detail
		if res.error.http_status != 0:
			fields["http"] = res.error.http_status
	_emit(
		level,
		channel,
		"%s: %s" % [what, res.error.message if res.error != null else "failed"],
		fields
	)


## True when a record at this level and channel would be emitted.
## Guard genuinely expensive message construction with it.
static func enabled(level: int, channel: String = "") -> bool:
	var threshold: int = _channel_levels.get(channel, _level) if channel != "" else _level
	return level >= threshold and threshold != Level.OFF


static func _emit(
	level: int,
	channel: String,
	message: String,
	fields: Dictionary
) -> void:
	if not enabled(level, channel):
		return

	var record := {
		"level": level,
		"level_name": LEVEL_NAMES[level],
		"channel": channel,
		"message": message,
		"fields": fields,
		# Monotonic. Wall-clock is added by sinks that want it, because
		# Time.get_unix_time_from_system() is comparatively expensive and most
		# lines never need it.
		"ticks_ms": Time.get_ticks_msec(),
	}

	var line := format_line(record)

	if print_to_stdout:
		# print() rather than printerr() even for errors: interleaving two
		# streams reorders a server log unreadably. Severity is in the tag.
		print(line)

	if mirror_to_engine and level >= mirror_min_level:
		if level == Level.WARN:
			push_warning(line)
		elif level >= Level.ERROR:
			push_error(line)

	for sink in _sinks:
		if sink.is_valid():
			sink.call(record)

	if _bus != null:
		_bus.record.emit(record)


## The one-line console format: [code]inf net  message key=value[/code].
static func format_line(record: Dictionary) -> String:
	var level: int = record.get("level", Level.INFO)
	var parts := PackedStringArray()

	if timestamps:
		parts.append(Time.get_time_string_from_system(true))

	parts.append(level_column(level))

	var channel: String = record.get("channel", "")
	if channel != "":
		parts.append("%-8s" % channel)

	parts.append(str(record.get("message", "")))

	var fields: Dictionary = record.get("fields", {})
	if not fields.is_empty():
		parts.append(format_fields(fields))

	return " ".join(parts)


## Renders structured fields as [code]key=value[/code] pairs, quoting only what
## needs it so the common case stays greppable.
static func format_fields(fields: Dictionary) -> String:
	var out := PackedStringArray()
	var keys := fields.keys()
	keys.sort()
	for k in keys:
		var v: Variant = fields[k]
		var s := str(v)
		if s.contains(" ") or s.contains("=") or s == "":
			s = "\"%s\"" % s.replace("\"", "\\\"")
		out.append("%s=%s" % [str(k), s])
	return " ".join(out)


## Renders a record as one JSON object per line, for log shippers.
static func format_json(record: Dictionary) -> String:
	var flat := {
		"level": record.get("level_name", ""),
		# The number as well as the name, because a collector sorting or filtering on
		# severity cannot do it on a string: "ERROR" < "INFO" < "WARN" alphabetically,
		# which orders them almost exactly wrong.
		"severity": record.get("level", Level.INFO),
		"channel": record.get("channel", ""),
		"message": record.get("message", ""),
		"t": record.get("ticks_ms", 0),
	}
	var fields: Dictionary = record.get("fields", {})
	for k in fields:
		# Namespaced so a field called "level" cannot shadow the real one.
		flat["f_" + str(k)] = fields[k]
	return JSON.stringify(flat)
