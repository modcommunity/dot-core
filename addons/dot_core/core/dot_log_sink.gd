@tool
class_name DotLogSink
extends Node

## Writes [DotLog] output to a rotating file, and optionally forwards it.
##
## Place one in the tree to give a server a durable log. Everything about where
## it writes and what it keeps is configurable, because a dedicated server's log
## policy is an operator decision: a box with 2 GB free wants aggressive
## rotation, a debugging session wants everything.
##
## [b]Buffered, not line-by-line.[/b] A busy server emits hundreds of lines a
## second and a [method FileAccess.flush] per line is a syscall per line — on web
## it is also an IndexedDB transaction per line, which is catastrophic. Lines
## accumulate and flush on a timer or when the buffer fills, so the worst case is
## losing [member flush_interval_sec] of log on a hard crash. [member flush_on_error]
## narrows that to zero for the lines that matter.

const CHANNEL := "logsink"

@export_group("File")

## Directory for log files. Supports [code]user://[/code] and absolute paths.
@export var directory: String = "user://logs"

## Base name. The rotation suffix and [code].log[/code] are appended.
@export var basename: String = "server"

## Whether to write a file at all. Off leaves only the forwarding sinks, which is
## what a browser build wants — there is nobody to read a file inside IndexedDB.
@export var write_file: bool = true

## Start a new file each run instead of appending.
##
## On by default: interleaved runs in one file make "what happened last night"
## much harder to answer than a directory listing does.
@export var new_file_per_run: bool = true

@export_group("Rotation")

## Rotate once the current file passes this size. 0 disables size rotation.
@export var max_file_bytes: int = 16 * 1024 * 1024

## Log files to keep, oldest deleted first. 0 keeps everything.
@export var max_files: int = 10

@export_group("Format")

## One JSON object per line instead of the human format.
##
## For servers whose logs are shipped to a collector. Off by default because the
## primary reader is an admin over SSH.
@export var json_lines: bool = false

## Minimum level this sink records, independent of [DotLog]'s own threshold.
##
## Lets a file keep DEBUG while the console shows INFO — the console has a human
## reading it in real time, the file has grep.
@export var level: DotLog.Level = DotLog.Level.DEBUG

## Include wall-clock timestamps in file output.
##
## On here even though [DotLog] defaults it off, because a file outlives the
## session that wrote it and a monotonic tick count is then meaningless.
@export var timestamps: bool = true

@export_group("Flushing")

@export_range(0.1, 60.0, 0.1) var flush_interval_sec: float = 2.0

## Lines buffered before an immediate flush.
@export_range(1, 10000, 1) var max_buffered_lines: int = 256

## Flush immediately on ERROR and above.
##
## The lines you most want after a crash are the ones written just before it, so
## these skip the buffer.
@export var flush_on_error: bool = true

@export_group("Forwarding")

## UDP destination for log forwarding, as [code]host:port[/code]. Empty disables.
##
## The familiar [code]logaddress_add[/code]: an admin panel or log host can
## tail a server without filesystem access. Unencrypted and unauthenticated, so
## keep it on a private network.
@export var forward_address: String = ""

var _buffer: PackedStringArray = PackedStringArray()
var _file: FileAccess = null
var _file_path: String = ""
var _bytes_written: int = 0
var _timer: Timer = null
var _udp: PacketPeerUDP = null
var _sink: Callable


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if write_file:
		var opened := _open_file()
		if not opened.ok:
			# A log sink that cannot open its file must not take the process
			# down with it, and must not fail silently either.
			DotLog.warn(
				CHANNEL, opened.error.message, {"detail": opened.error.detail}
			)

	if forward_address != "":
		_setup_forwarding()

	_timer = Timer.new()
	_timer.wait_time = flush_interval_sec
	_timer.autostart = true
	_timer.timeout.connect(flush)
	add_child(_timer)

	_sink = _on_record
	DotLog.add_sink(_sink)

	DotLog.info(
		CHANNEL,
		"log sink started",
		{"path": _file_path if write_file else "<none>"}
	)


func _exit_tree() -> void:
	if _sink.is_valid():
		DotLog.remove_sink(_sink)
	flush()
	if _file != null:
		_file.close()
		_file = null
	if _udp != null:
		_udp.close()
		_udp = null


# --- Record handling -------------------------------------------------------

func _on_record(record: Dictionary) -> void:
	var rec_level: int = record.get("level", DotLog.Level.INFO)
	if rec_level < level:
		return

	var line := _format(record)
	_buffer.append(line)

	if _udp != null:
		# The established log protocol is a plain UTF-8 line; anything tailing this is
		# reading text, so no framing is added.
		_udp.put_packet((line + "\n").to_utf8_buffer())

	if _buffer.size() >= max_buffered_lines:
		flush()
	elif flush_on_error and rec_level >= DotLog.Level.ERROR:
		flush()


func _format(record: Dictionary) -> String:
	if json_lines:
		return DotLog.format_json(record)

	var parts := PackedStringArray()

	if timestamps:
		# ISO-8601-ish and sortable, which is what makes `sort` on a merged log
		# from three servers produce something readable.
		parts.append(
			Time.get_datetime_string_from_system(true, true)
		)

	parts.append(DotLog.LEVEL_TAGS[int(record.get("level", 2))])

	var channel: String = record.get("channel", "")
	if channel != "":
		parts.append("%-8s" % channel)

	parts.append(str(record.get("message", "")))

	var fields: Dictionary = record.get("fields", {})
	if not fields.is_empty():
		parts.append(DotLog.format_fields(fields))

	return " ".join(parts)


# --- File management -------------------------------------------------------

func _open_file() -> DotResult:
	var dir_res := DotPaths.ensure_dir(directory)
	if not dir_res.ok:
		return dir_res

	var filename := basename
	if new_file_per_run:
		# Sortable, filesystem-safe, and unique per second — enough, because two
		# server starts inside one second would be a restart loop worth noticing.
		var stamp := Time.get_datetime_string_from_system(false, false)
		filename += "-" + stamp.replace(":", "").replace("-", "").replace("T", "-")
	filename += ".log"

	_file_path = directory.path_join(filename)

	var mode := FileAccess.WRITE if new_file_per_run else FileAccess.READ_WRITE
	_file = FileAccess.open(_file_path, mode)

	if _file == null and mode == FileAccess.READ_WRITE:
		# READ_WRITE does not create the file; first run needs WRITE.
		_file = FileAccess.open(_file_path, FileAccess.WRITE)

	if _file == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(),
				"opening log file '%s'" % _file_path
			)
		)

	if not new_file_per_run:
		_file.seek_end()
		_bytes_written = _file.get_position()
	else:
		_bytes_written = 0

	_prune_old_files()
	return DotResult.success(_file_path)


## Writes the buffer out. Safe to call at any time.
func flush() -> void:
	if _buffer.is_empty():
		return

	var text := "\n".join(_buffer) + "\n"
	_buffer.clear()

	if _file == null:
		return

	_file.store_string(text)
	_file.flush()
	_bytes_written += text.to_utf8_buffer().size()

	# Persist through IndexedDB on web, where an unsynced write is lost on tab
	# close — which is exactly when you want the log.
	DotWeb.sync_filesystem()

	if max_file_bytes > 0 and _bytes_written >= max_file_bytes:
		_rotate()


func _rotate() -> void:
	DotLog.debug(CHANNEL, "rotating log", {"bytes": _bytes_written})

	if _file != null:
		_file.close()
		_file = null

	# Rotating by opening a fresh timestamped file rather than renaming: renames
	# of an open file behave differently across the five target platforms, and
	# the timestamp already makes ordering obvious.
	var saved := new_file_per_run
	new_file_per_run = true
	var res := _open_file()
	new_file_per_run = saved

	if not res.ok:
		DotLog.warn(CHANNEL, "rotation failed", {"detail": res.error.detail})


func _prune_old_files() -> void:
	if max_files <= 0:
		return

	var names := PackedStringArray()
	var dir := DirAccess.open(directory)
	if dir == null:
		return

	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.begins_with(basename) and n.ends_with(".log"):
			names.append(n)
		n = dir.get_next()
	dir.list_dir_end()

	if names.size() <= max_files:
		return

	# Names carry a sortable timestamp, so lexical order is chronological.
	names.sort()

	var excess := names.size() - max_files
	for i in range(excess):
		var victim := directory.path_join(names[i])
		if victim == _file_path:
			continue
		DirAccess.remove_absolute(victim)
		DotLog.debug(CHANNEL, "pruned old log", {"file": names[i]})


func _setup_forwarding() -> void:
	var parts := forward_address.rsplit(":", true, 1)
	if parts.size() != 2 or not parts[1].is_valid_int():
		DotLog.warn(
			CHANNEL,
			"forward_address must be host:port",
			{"value": forward_address}
		)
		return

	if not DotPlatform.has_udp():
		DotLog.warn(
			CHANNEL, "log forwarding needs UDP, which this platform lacks"
		)
		return

	_udp = PacketPeerUDP.new()
	var err := _udp.connect_to_host(parts[0], parts[1].to_int())
	if err != OK:
		DotLog.warn(
			CHANNEL,
			"could not set up log forwarding",
			{"detail": error_string(err)}
		)
		_udp = null
		return

	DotLog.info(CHANNEL, "forwarding logs", {"to": forward_address})


func describe() -> Dictionary:
	return {
		"path": _file_path,
		"buffered": _buffer.size(),
		"bytes": _bytes_written,
		"forwarding": forward_address,
		"level": DotLog.level_name(level),
	}
