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

## The six levels, and what each one means here.
##
## [b]A level is a promise to the person reading, not a volume knob.[/b] These are the
## levels every log system in the industry converged on, and they are only useful if a
## server agrees with every other server about which is which — an admin who has learned
## that ERROR means "something failed" stops reading them the first time one turns out to
## mean "a player typed an unknown command".
##
## The test for each is in the right-hand column: who is expected to do something, and
## when.
##
## [codeblock]
## TRACE  per-frame, per-packet, per-entity     nobody; you are debugging right now
## DEBUG  a decision or a state transition      you, later, reading it back
## INFO   something an admin would want kept    nobody; it is the record
## WARN   recoverable, and somebody should look eventually
## ERROR  the operation failed                  somebody, today
## FATAL  the process cannot continue           somebody, now
## [/codeblock]
enum Level {
	## Per-frame or per-packet detail. Off outside debugging.
	##
	## The level whose cost is the message itself: guard an expensive one with
	## [method enabled], because building a formatted dump of 64 entities in order to
	## drop it is the one cost a levelled logger cannot optimise away.
	TRACE,

	## Decisions and state transitions. What you turn on to answer "why did it do that".
	DEBUG,

	## Things an admin would want in the log by default.
	##
	## A map change, a player admitted, a service listening. The default threshold, so
	## anything at this level is something you are willing to have in every log forever.
	INFO,

	## Recoverable; someone should look eventually.
	##
	## The operation continued, possibly degraded. An optional lookup that was refused, a
	## vote that cannot open yet, a config key that was ignored. [b]This level does not
	## mirror to the engine[/b] — see [member mirror_min_level] for why.
	WARN,

	## The operation failed.
	##
	## Something a caller asked for did not happen, and the caller was told. The server is
	## still running and the next request may well work.
	ERROR,

	## The process cannot continue.
	##
	## [b]Reserve this one.[/b] FATAL means a crash or a total breakage: boot failed, the
	## listener could not be opened, the state the process needs is gone. It is not "a
	## very bad error" — it is a promise that what follows this line is a shutdown, and
	## the value of the promise is entirely in how rarely it is made. There is exactly one
	## FATAL in this whole family, in [code]DotServer._boot_failed[/code], and that is the
	## right number of them.
	##
	## A sink is entitled to treat it specially: dot-log flushes every target immediately
	## on one, because a record still sitting in a buffer when the process goes is a
	## record that was never written.
	FATAL,

	## Never emitted. Only valid as a threshold.
	OFF,
}


## How the level is rendered in the console line.
##
## The level is [b]always[/b] printed — the question is only how wide. Tags are the
## default because they are a fixed three characters, so the message column lines up in a
## wall of them and the eye finds the upper-case ones without reading. Names are for a
## log something else parses by eye or by column, and for anyone who would rather not
## learn that [code]FTL[/code] is fatal.
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

## Whether to also route the serious levels through [method push_warning] /
## [method push_error] so failures surface in the editor's Errors dock and in
## crash reports. Off in exported builds by default: the sinks own the log
## there, and duplicating every warning into stderr doubles a busy server's
## output for no reader.
static var mirror_to_engine: bool = OS.is_debug_build()

## The lowest level [member mirror_to_engine] actually mirrors.
##
## [b]ERROR rather than WARN, because of what the engine adds.[/b] In a debug
## build [method push_warning] prints the message, then an [code]at:[/code] line
## naming a file inside the engine's own source, then a GDScript backtrace — and
## none of that is suppressible per call. [method Engine.print_error_messages] is
## the only switch and it silences real runtime errors too, so it is not one you
## want left off in a server.
##
## The result is that a recoverable, entirely expected warning — an optional
## profile lookup that was refused, a vote that cannot open yet — costs eight
## lines of stderr and looks, to an admin reading the log, exactly like a crash.
## The [code]WRN[/code] line this class prints itself already carries the same
## message, so the mirror was adding a stack trace and nothing else.
##
## ERROR and above keep it: there the stack [i]is[/i] the information, and there
## are few enough of them that the noise is worth the origin. Set this to
## [constant Level.WARN] while hunting the source of a specific warning.
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


## The level as it appears in a console line, padded to a fixed width.
##
## Fixed width in both styles, because the whole reason the level goes first is that a
## reader scanning a hundred lines finds the message column in the same place on each.
static func level_column(level: int) -> String:
	if level < 0 or level >= LEVEL_NAMES.size():
		return "???" if level_style == LevelStyle.TAG else "?????"
	if level_style == LevelStyle.NAME:
		return "%-5s" % LEVEL_NAMES[level]
	return LEVEL_TAGS[level]


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


## Logs at a level chosen at runtime.
##
## The six named functions above are what code should call — a level written into the
## call is a level a reader can grep for. This is for the cases where the level genuinely
## is data: a console command that emits a test record, a config-driven severity, a bridge
## replaying records that arrived from somewhere else with their own level attached.
##
## [constant Level.OFF] is refused rather than silently dropped, because "log this at OFF"
## is a caller that has confused a threshold with a severity and would otherwise never
## find out.
static func at(
	level: int, channel: String, message: String, fields: Dictionary = {}
) -> void:
	if level < Level.TRACE or level >= Level.OFF:
		push_error("DotLog.at() with a level that is not one of the six: %d" % level)
		return
	_emit(level, channel, message, fields)


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
