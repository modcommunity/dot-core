class_name DotLog
extends RefCounted

## Levelled, channelled logging with pluggable sinks.
##
## A dedicated server's log is an operational artefact, not developer noise:
## admins grep it, moderation decisions are justified from it, and on a headless
## box it is the only UI. So this is deliberately more than a [method print]
## wrapper — it carries a channel (which subsystem), a level (how much you care)
## and structured fields (what the machine needs), and it fans out to as many
## sinks as are attached.
##
## Static rather than an autoload because a logger you cannot call from a
## [Resource], a static function or an early [method _init] is a logger people
## work around. Configure it once at boot:
##
## [codeblock]
## DotLog.set_level(DotLog.Level.INFO)
## DotLog.set_channel_level("net", DotLog.Level.DEBUG)  # noisy, just this one
## DotLog.info("server", "listening", {"port": 27015})
## [/codeblock]
##
## To capture output (a file, an in-game console, UDP forwarding to a log host)
## attach a [DotLogSink] node or register a [Callable] via [method add_sink].

enum Level {
	TRACE,   ## Per-frame or per-packet detail. Off outside debugging.
	DEBUG,   ## Decisions and state transitions.
	INFO,    ## Things an admin would want in the log by default.
	WARN,    ## Recoverable; someone should look eventually.
	ERROR,   ## The operation failed.
	FATAL,   ## The process cannot continue.
	OFF,     ## Never emitted. Only valid as a threshold.
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

## Whether to also route WARN+ through [method push_warning] /
## [method push_error] so failures surface in the editor's Errors dock and in
## crash reports. Off in exported builds by default: the sinks own the log
## there, and duplicating every warning into stderr doubles a busy server's
## output for no reader.
static var mirror_to_engine: bool = OS.is_debug_build()

## Whether to print to stdout. A dedicated server wants this on; a shipped
## client usually wants only the file sink.
static var print_to_stdout: bool = true

## Include a wall-clock timestamp. Off by default because most sinks (files,
## journald, the editor) add their own, and two timestamps per line is worse
## than none.
static var timestamps: bool = false

## Emitted for every record that passes the level filter, after the sinks run.
## Wired through a hidden singleton node so that UI can `connect` to it without
## dot-core owning an autoload; see [method signals].
static var _bus: DotLogBus = null


# --- Configuration ---------------------------------------------------------

static func set_level(level: int) -> void:
	_level = clampi(level, Level.TRACE, Level.OFF)


static func get_level() -> int:
	return _level


## Raise or lower the threshold for one channel only.
##
## The reason level-per-channel exists: turning on DEBUG globally to diagnose a
## download bug also turns on every physics and RPC trace, and the interesting
## lines scroll past. Pass [constant Level.OFF] to silence a channel entirely.
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


# --- Sinks -----------------------------------------------------------------

## Registers a sink. The callable receives one [Dictionary] record; see
## [method _emit] for its shape.
##
## Sinks are called synchronously in registration order. A sink that blocks
## blocks the frame, so file sinks buffer and flush on a timer rather than
## writing per line — see [DotLogSink].
static func add_sink(sink: Callable) -> void:
	if not _sinks.has(sink):
		_sinks.append(sink)


static func remove_sink(sink: Callable) -> void:
	_sinks.erase(sink)


static func clear_sinks() -> void:
	_sinks.clear()


static func sink_count() -> int:
	return _sinks.size()


## A [DotLogBus] carrying a `record` signal, for UI that would rather connect
## than register a callable. Created on first use.
static func signals() -> DotLogBus:
	if _bus == null:
		_bus = DotLogBus.new()
	return _bus


# --- Emitting --------------------------------------------------------------

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


## Logs a [DotResult] failure at ERROR, or nothing at all on success.
##
## Collapses the extremely common three-line "if not res.ok: log; return" into
## one call at the sites where the caller has nothing to add.
static func result(channel: String, what: String, res: DotResult) -> void:
	if res == null or res.ok:
		return
	var fields := {"code": res.code()}
	if res.error != null:
		if res.error.detail != "":
			fields["detail"] = res.error.detail
		if res.error.http_status != 0:
			fields["http"] = res.error.http_status
	_emit(
		Level.ERROR,
		channel,
		"%s: %s" % [what, res.error.message if res.error != null else "failed"],
		fields
	)


## True when a record at this level and channel would be emitted.
##
## Guard genuinely expensive message construction with this — building a
## formatted dump of 64 entities only to drop it is the one real cost a levelled
## logger cannot optimise away on its own.
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

	if mirror_to_engine:
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

	parts.append(LEVEL_TAGS[level])

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
		"channel": record.get("channel", ""),
		"message": record.get("message", ""),
		"t": record.get("ticks_ms", 0),
	}
	var fields: Dictionary = record.get("fields", {})
	for k in fields:
		# Namespaced so a field called "level" cannot shadow the real one.
		flat["f_" + str(k)] = fields[k]
	return JSON.stringify(flat)
