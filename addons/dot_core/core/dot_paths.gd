class_name DotPaths
extends RefCounted

## Filesystem helpers with the cross-platform sharp edges handled.
##
## Three things go wrong when writing user data in a project that ships to five
## platforms and downloads content at runtime:
##
## 1. [b]Web needs an explicit flush.[/b] See [method DotWeb.sync_filesystem].
##    Every write helper here syncs, so no caller has to remember.
## 2. [b]Server-supplied paths are attacker-controlled.[/b] A content manifest
##    naming [code]../../../.ssh/id_rsa[/code] must not escape the cache
##    directory. [method safe_relative] is the chokepoint and it is not
##    optional.
## 3. [b]`user://` is not one place.[/b] Desktop gives a real directory, mobile
##    an app sandbox, web an IndexedDB mirror. Code that treats it as a disk
##    path (passing it to an OS call, printing it in a support message) is wrong
##    on two of the three.

const CHANNEL := "paths"

## Path segments that are never legal in content-supplied relative paths, on any
## platform. Checked case-insensitively without extension because Windows
## resolves [code]NUL.txt[/code] to the device too.
const WINDOWS_RESERVED: Array[String] = [
	"CON", "PRN", "AUX", "NUL",
	"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
	"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
]

## Characters no platform in the target set accepts in a filename.
const ILLEGAL_CHARS := "\\:*?\"<>|"


# --- Sanitisation ----------------------------------------------------------

## Validates a relative path from an untrusted source and returns it normalised.
##
## Returns a failed [DotResult] rather than a sanitised guess. Silently
## rewriting [code]../../etc/passwd[/code] into [code]etc/passwd[/code] would
## write an attacker's file somewhere valid and report success; a manifest with
## a traversal in it is malformed and the right answer is to refuse the whole
## manifest.
##
## Enforced: relative only, no [code]..[/code] segment anywhere, no leading
## slash, no drive letter, no NUL or control characters, no Windows reserved
## device names, no trailing dots or spaces (Windows silently strips them, so
## two entries could collide), and a length ceiling.
static func safe_relative(path: String, max_length: int = 1024) -> DotResult:
	if path.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "Empty path.")

	if path.length() > max_length:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Path is too long.",
			"%d > %d" % [path.length(), max_length]
		)

	# Backslashes are normalised first so a Windows-style traversal cannot slip
	# past the ".." check below.
	var p := path.replace("\\", "/")

	if p.begins_with("/"):
		return DotResult.fail(
			DotError.CODE_INVALID, "Path must be relative.", path
		)

	# A Godot scheme or a Windows drive letter both mean "not relative".
	if p.contains("://") or (p.length() >= 2 and p[1] == ":"):
		return DotResult.fail(
			DotError.CODE_INVALID, "Path must be relative.", path
		)

	for i in range(p.length()):
		var c := p.unicode_at(i)
		if c < 32 or c == 127:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Path contains a control character.",
				path
			)

	var out := PackedStringArray()
	for seg in p.split("/", false):
		if seg == "." :
			continue
		if seg == "..":
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Path traversal is not allowed.",
				path
			)

		for ch in ILLEGAL_CHARS:
			if seg.contains(ch):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"Path contains an illegal character '%s'." % ch,
					path
				)

		# Trailing dots and spaces: Windows drops them at creation time, so
		# "a." and "a" would become the same file while the manifest believes
		# they are two.
		if seg.ends_with(".") or seg.ends_with(" ") or seg.begins_with(" "):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Path segment has leading or trailing whitespace or a trailing dot.",
				path
			)

		var stem := seg.get_basename().to_upper()
		if WINDOWS_RESERVED.has(stem):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Path uses the reserved device name '%s'." % stem,
				path
			)

		out.append(seg)

	if out.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "Path resolves to nothing.", path
		)

	return DotResult.success("/".join(out))


## Rewrites a string so it is safe to use as a single filename component.
##
## Unlike [method safe_relative] this DOES mangle its input, because the input
## is a label (a game id, a server name) rather than a path — losing information
## is the point. Never use it to sanitise a path: it would flatten
## [code]a/../b[/code] into a legal-looking name.
static func slugify(s: String, max_length: int = 64) -> String:
	var out := ""
	for i in range(s.length()):
		var c := s[i]
		if c.is_valid_identifier() or c.is_valid_int() or c == "-" or c == "_":
			out += c.to_lower()
		elif c == " " or c == "." or c == "/":
			out += "_"
		# Everything else is dropped rather than substituted: a name that is
		# all punctuation should come out empty and be rejected, not become
		# a row of underscores that collides with every other such name.

	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.trim_prefix("_").trim_suffix("_")

	if out.length() > max_length:
		out = out.substr(0, max_length)

	return out


# --- Directories -----------------------------------------------------------

## Creates a directory and every missing parent.
static func ensure_dir(path: String) -> DotResult:
	if DirAccess.dir_exists_absolute(path):
		return DotResult.success(path)

	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "creating directory '%s'" % path)
		)

	return DotResult.success(path)


## Creates the parent directory of a file path.
static func ensure_parent_dir(file_path: String) -> DotResult:
	return ensure_dir(file_path.get_base_dir())


## Removes a directory and everything under it.
##
## Walks depth-first because [method DirAccess.remove_absolute] refuses a
## non-empty directory. Reports the first failure but keeps going, so a single
## locked file does not leave most of a cache behind.
static func remove_tree(path: String) -> DotResult:
	if not DirAccess.dir_exists_absolute(path):
		return DotResult.success(0)

	var removed := 0
	var first_error: DotError = null

	var dir := DirAccess.open(path)
	if dir == null:
		return DotResult.failure(
			DotError.from_engine(
				DirAccess.get_open_error(), "opening '%s'" % path
			)
		)

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var child := path.path_join(name)
		if dir.current_is_dir():
			var sub := remove_tree(child)
			if sub.ok:
				removed += int(sub.value_or(0))
			elif first_error == null:
				first_error = sub.error
		else:
			var err := DirAccess.remove_absolute(child)
			if err == OK:
				removed += 1
			elif first_error == null:
				first_error = DotError.from_engine(err, "removing '%s'" % child)
		name = dir.get_next()
	dir.list_dir_end()

	var err2 := DirAccess.remove_absolute(path)
	if err2 != OK and first_error == null:
		first_error = DotError.from_engine(err2, "removing '%s'" % path)

	DotWeb.sync_filesystem()

	if first_error != null:
		return DotResult.failure(first_error)
	return DotResult.success(removed)


## Every file under [param path], as paths relative to it.
static func list_files_recursive(
	path: String,
	prefix: String = ""
) -> PackedStringArray:
	var out := PackedStringArray()

	var dir := DirAccess.open(path)
	if dir == null:
		return out

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var rel := name if prefix == "" else prefix + "/" + name
		if dir.current_is_dir():
			out.append_array(
				list_files_recursive(path.path_join(name), rel)
			)
		else:
			out.append(rel)
		name = dir.get_next()
	dir.list_dir_end()

	return out


# --- Reading and writing ---------------------------------------------------

static func read_bytes(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(
			DotError.CODE_IO, "File not found.", path
		)

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(), "opening '%s'" % path
			)
		)

	var bytes := f.get_buffer(f.get_length())
	f.close()
	return DotResult.success(bytes)


static func read_text(path: String) -> DotResult:
	var res := read_bytes(path)
	if not res.ok:
		return res
	var bytes: PackedByteArray = res.value
	return DotResult.success(bytes.get_string_from_utf8())


static func read_json(path: String) -> DotResult:
	var res := read_text(path)
	if not res.ok:
		return res

	var text: String = res.value
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"Malformed JSON in '%s'." % path,
			"line %d: %s" % [json.get_error_line(), json.get_error_message()]
		)

	return DotResult.success(json.data)


## Writes bytes, creating parents and flushing the web filesystem.
##
## [param atomic] writes to a sibling [code].tmp[/code] and renames, so a crash
## or a closed tab leaves either the old file or the new one and never a
## half-written one. On by default: every caller in dot-* writes cache entries
## whose truncation would be indistinguishable from corruption.
static func write_bytes(
	path: String,
	bytes: PackedByteArray,
	atomic: bool = true
) -> DotResult:
	var parent := ensure_parent_dir(path)
	if not parent.ok:
		return parent

	var target := path + ".tmp" if atomic else path

	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(), "opening '%s' for write" % target
			)
		)

	f.store_buffer(bytes)
	f.close()

	if atomic:
		var dir := DirAccess.open(path.get_base_dir())
		if dir == null:
			return DotResult.failure(
				DotError.from_engine(
					DirAccess.get_open_error(),
					"opening '%s'" % path.get_base_dir()
				)
			)
		# rename() does not overwrite on every platform, so clear the target.
		if FileAccess.file_exists(path):
			dir.remove(path.get_file())
		var err := dir.rename(target.get_file(), path.get_file())
		if err != OK:
			return DotResult.failure(
				DotError.from_engine(err, "renaming '%s'" % target)
			)

	DotWeb.sync_filesystem()
	return DotResult.success(bytes.size())


static func write_text(
	path: String,
	text: String,
	atomic: bool = true
) -> DotResult:
	return write_bytes(path, text.to_utf8_buffer(), atomic)


static func write_json(
	path: String,
	data: Variant,
	pretty: bool = true,
	atomic: bool = true
) -> DotResult:
	var text := JSON.stringify(data, "\t" if pretty else "")
	return write_text(path, text, atomic)


## Writes bytes encrypted with a passphrase.
##
## Used by dot-auth's token store. On web the key travels with the ciphertext in
## the same origin, so this is tamper-evidence and obfuscation rather than
## confidentiality against someone with devtools open — dot-auth documents that
## where it matters.
static func write_encrypted(
	path: String,
	bytes: PackedByteArray,
	passphrase: String
) -> DotResult:
	var parent := ensure_parent_dir(path)
	if not parent.ok:
		return parent

	var f := FileAccess.open_encrypted_with_pass(
		path, FileAccess.WRITE, passphrase
	)
	if f == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(),
				"opening '%s' for encrypted write" % path
			)
		)

	f.store_buffer(bytes)
	f.close()

	DotWeb.sync_filesystem()
	return DotResult.success(bytes.size())


## Reads a file written by [method write_encrypted].
##
## A wrong passphrase and a corrupt file are indistinguishable here — both fail
## to open. Callers treat that as "no stored credential" and re-authenticate
## rather than surfacing it, because the most common cause is a key derived from
## machine identity on a machine that changed.
static func read_encrypted(path: String, passphrase: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_IO, "File not found.", path)

	var f := FileAccess.open_encrypted_with_pass(
		path, FileAccess.READ, passphrase
	)
	if f == null:
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"Could not decrypt '%s'." % path,
			"wrong key or corrupt file"
		)

	var bytes := f.get_buffer(f.get_length())
	f.close()
	return DotResult.success(bytes)


## Appends one file onto another without reading either into memory.
##
## Exists for resumed downloads. [HTTPRequest] has no append mode — it truncates
## whatever [member HTTPRequest.download_file] points at — so a ranged response
## has to land in a sibling file and be joined on here. Streaming matters for the
## same reason the file-based download exists at all: concatenating a 500 MB pack
## through a [PackedByteArray] costs the memory that download was avoiding.
##
## [param at_offset] truncates [param dest_path] to that length before writing, so
## a partial longer than the range that was actually requested cannot leave stale
## bytes past the join. A negative offset appends at the current end.
static func append_file(
	dest_path: String,
	src_path: String,
	at_offset: int = -1,
	chunk_bytes: int = 1 << 20
) -> DotResult:
	var parent := ensure_parent_dir(dest_path)
	if not parent.ok:
		return parent

	var src := FileAccess.open(src_path, FileAccess.READ)
	if src == null:
		return DotResult.failure(DotError.from_engine(
			FileAccess.get_open_error(), "opening '%s' for read" % src_path
		))

	# READ_WRITE preserves what is already there; WRITE would truncate it, which
	# is the exact behaviour this function exists to work around.
	var existing := file_size(dest_path)
	var dst := FileAccess.open(
		dest_path,
		FileAccess.READ_WRITE if existing >= 0 else FileAccess.WRITE
	)
	if dst == null:
		src.close()
		return DotResult.failure(DotError.from_engine(
			FileAccess.get_open_error(), "opening '%s' to append to" % dest_path
		))

	if at_offset > max(existing, 0):
		# Seeking past the end would punch a hole and call it a file. The caller
		# has mismatched its own bookkeeping; say so rather than write garbage.
		src.close()
		dst.close()
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Cannot append past the end of the destination.",
			"offset %d, '%s' is %d bytes" % [at_offset, dest_path, max(existing, 0)]
		)

	if at_offset >= 0:
		if at_offset < max(existing, 0):
			dst.resize(at_offset)
		dst.seek(at_offset)
	else:
		dst.seek_end()

	var written := 0
	var step := maxi(chunk_bytes, 4096)

	while not src.eof_reached():
		var buf := src.get_buffer(step)
		if buf.is_empty():
			break
		dst.store_buffer(buf)
		written += buf.size()

	var err := dst.get_error()
	src.close()
	dst.close()

	if err != OK and err != ERR_FILE_EOF:
		return DotResult.failure(
			DotError.from_engine(err, "appending to '%s'" % dest_path)
		)

	DotWeb.sync_filesystem()
	return DotResult.success(written)


## Replaces [param dest_path] with [param src_path], removing the source.
##
## A rename rather than a copy, so swapping in a downloaded file that is already
## complete costs nothing regardless of its size.
static func replace_file(dest_path: String, src_path: String) -> DotResult:
	var dir := DirAccess.open(src_path.get_base_dir())
	if dir == null:
		return DotResult.failure(DotError.from_engine(
			DirAccess.get_open_error(), "opening '%s'" % src_path.get_base_dir()
		))

	# rename() does not overwrite on every platform, so clear the target first.
	if FileAccess.file_exists(dest_path):
		dir.remove(dest_path)

	var err := dir.rename(src_path, dest_path)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "renaming '%s'" % src_path)
		)

	DotWeb.sync_filesystem()
	return DotResult.success(file_size(dest_path))


static func file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


# --- Reporting -------------------------------------------------------------

## A human-readable byte count for progress UI and log lines.
static func format_bytes(n: int) -> String:
	if n < 0:
		return "?"
	if n < 1024:
		return "%d B" % n

	var units := ["KiB", "MiB", "GiB", "TiB"]
	var v := float(n) / 1024.0
	var i := 0
	while v >= 1024.0 and i < units.size() - 1:
		v /= 1024.0
		i += 1

	return "%.1f %s" % [v, units[i]]


## Where user data actually lives, for support messages.
##
## On web this is a virtual path with no disk behind it, which is why it is
## labelled rather than printed bare.
static func describe_user_dir() -> String:
	var base := OS.get_user_data_dir()
	if DotPlatform.is_web():
		return "%s (browser storage — not a real directory)" % base
	return base
