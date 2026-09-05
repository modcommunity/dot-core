class_name DotHashJob
extends DotJob

## Hashes a file in chunks, so a multi-gigabyte verify does not drop frames.
##
## Submit to a [DotScheduler]; on desktop it runs on a worker thread, on
## single-threaded web builds it is sliced against the frame budget. Either way
## the result is the file's SHA-256 as a lowercase hex string.
##
## [codeblock]
## var job := DotHashJob.new("user://dot_cloud/objects/ab/abcd…", expected_hex)
## var res := await scheduler.run(job)
## if not res.ok: ...          # unreadable file, or hash mismatch
## [/codeblock]

## Chunks read per [method _step]. One 256 KiB read per step keeps a slice at
## roughly a third of a millisecond on desktop.
const CHUNKS_PER_STEP := 1

var path: String
var expected: String

var _file: FileAccess = null
var _ctx: HashingContext = null
var _total: int = 0
var _read: int = 0


## [param p_expected] is optional. When given, a mismatch is reported as a
## [constant DotError.CODE_INTEGRITY] failure rather than returning the wrong
## hash for the caller to compare — which means no call site can forget to
## compare.
func _init(p_path: String, p_expected: String = "") -> void:
	path = p_path
	expected = p_expected.to_lower()
	name = "hash %s" % path.get_file()


func _setup() -> void:
	if not FileAccess.file_exists(path):
		_finish(DotResult.fail(DotError.CODE_IO, "File not found.", path))
		return

	_file = FileAccess.open(path, FileAccess.READ)
	if _file == null:
		_finish(DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(), "opening '%s'" % path
			)
		))
		return

	_total = _file.get_length()

	_ctx = HashingContext.new()
	var err := _ctx.start(HashingContext.HASH_SHA256)
	if err != OK:
		_finish(DotResult.failure(
			DotError.from_engine(err, "starting SHA-256")
		))


func _step() -> bool:
	if _file == null or _ctx == null:
		return false

	for _i in range(CHUNKS_PER_STEP):
		if _file.eof_reached():
			return _complete()

		var chunk := _file.get_buffer(DotHash.CHUNK_SIZE)
		if chunk.is_empty():
			return _complete()

		_ctx.update(chunk)
		_read += chunk.size()

	return true


func _complete() -> bool:
	var digest := _ctx.finish().hex_encode()

	if expected != "" and not DotHash.constant_time_equal_hex(digest, expected):
		_finish(DotResult.fail(
			DotError.CODE_INTEGRITY,
			"Content does not match its expected hash.",
			"%s: expected %s, got %s" % [
				path.get_file(), expected.substr(0, 16), digest.substr(0, 16)
			]
		))
		return false

	_finish(DotResult.success(digest))
	return false


func _progress() -> float:
	if _total <= 0:
		return -1.0
	return clampf(float(_read) / float(_total), 0.0, 1.0)


func _teardown() -> void:
	if _file != null:
		_file.close()
		_file = null
	_ctx = null
