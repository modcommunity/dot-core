extends Node

## Exercises DotHttp and the filesystem helpers it leans on, against a real
## socket, headless.
##
## [codeblock]
## godot --headless --path . res://examples/http_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## [b]Why a server lives in this file.[/b] Everything interesting about
## [method DotHttp.download_to_file] is in how it reacts to what a server sends
## back — a 206 that continues a partial, a 200 from a host that ignored the
## [code]Range[/code] header entirely, a 416, a 500 mid-resume. None of that is
## reachable without something on the other end of a socket, and mocking
## [HTTPRequest] would test the mock. So this binds a loopback port and speaks
## enough HTTP/1.1 to answer the four shapes that matter. dot-auth's issuer does
## the same thing for the same reason.
##
## The resume cases are the point. [HTTPRequest] has no append mode, so the
## whole of resuming a download is what dot-core does *around* it, and a resume
## that silently writes only the tail of a file passes every check that looks at
## the response rather than the bytes on disk.

const PORT_FIRST := 28230
const PORT_LAST := 28330

# Long enough that a truncated result is obvious in a byte count rather than
# needing a diff, and not so long that the server has to think about framing.
const BODY := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\
abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server := TCPServer.new()
var _clients: Array[StreamPeerTCP] = []
var _port := 0

## What the next request gets. Set per case.
var _mode := "range"
var _requests: Array[Dictionary] = []

var _http: DotHttp


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("dot-core HTTP self-test")
	print("")

	if not _listen():
		print("  FAIL  could not bind a loopback port in %d-%d" % [PORT_FIRST, PORT_LAST])
		get_tree().quit(1)
		return

	_http = DotHttp.new()
	# Retries would turn a deliberate 500 into three of them and hide which
	# attempt the assertions are about.
	_http.max_retries = 0
	add_child(_http)

	await _test_plain_download()
	await _test_resume_joins()
	await _test_resume_ignored_range()
	await _test_resume_failure_preserves_partial()
	await _test_range_not_satisfiable()
	_test_append_file()
	_test_replace_file()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Downloads -------------------------------------------------------------

func _test_plain_download() -> void:
	_group("a download with no range at all")

	var dest := _scratch("plain.bin")
	_mode = "range"

	var res := await _http.download_to_file(_url(), dest)

	_check(res.ok, "succeeds", "" if res.ok else res.error.message)
	if res.ok:
		var d: Dictionary = res.value
		_check(int(d["status"]) == 200, "answers 200")
		_check(not bool(d["resumed"]), "and does not claim to have resumed")
	_check(_read(dest) == BODY, "and writes the whole body")
	_check(not FileAccess.file_exists(dest + ".resume"), "leaving no sibling behind")


func _test_resume_joins() -> void:
	_group("a resumed download")

	# The shape dot-cloud produces: an interrupted transfer left a prefix on
	# disk and its length is the offset asked for.
	var dest := _scratch("resume.bin")
	var have := 40
	_write(dest, BODY.substr(0, have))
	_mode = "range"

	var res := await _http.download_to_file(_url(), dest, have)

	_check(res.ok, "succeeds", "" if res.ok else res.error.message)
	_check(_requests.size() > 0 and str(_requests[-1].get("range", "")) == "bytes=%d-" % have,
		"asks for exactly the bytes it is missing",
		str(_requests[-1].get("range", "")) if _requests.size() > 0 else "no request")

	if res.ok:
		var d: Dictionary = res.value
		_check(int(d["status"]) == 206, "and is answered 206")
		_check(bool(d["resumed"]), "and reports resumed")
		_check(int(d["size"]) == BODY.length(),
			"and reports the size of the whole file, not of the range",
			"%d vs %d" % [int(d["size"]), BODY.length()])

	# The assertion this file exists for. HTTPRequest truncates download_file,
	# so the naive implementation leaves the tail of the file where the file
	# should be — the right length is not enough, the prefix has to survive.
	var got := _read(dest)
	_check(got == BODY,
		"and the bytes already on disk are still in front of the ones that arrived",
		"got %d bytes: %s" % [got.length(), got.substr(0, 24)])
	_check(not FileAccess.file_exists(dest + ".resume"),
		"and the sibling it staged through is cleaned up")


func _test_resume_ignored_range() -> void:
	_group("a resume against a host that ignores Range")

	# Plenty of static hosts and proxies answer 200 with the whole body. The
	# response is a complete file, so appending it would give the prefix twice.
	var dest := _scratch("ignored.bin")
	var have := 40
	_write(dest, BODY.substr(0, have))
	_mode = "ignore-range"

	var res := await _http.download_to_file(_url(), dest, have)

	_check(res.ok, "succeeds", "" if res.ok else res.error.message)
	if res.ok:
		var d: Dictionary = res.value
		_check(int(d["status"]) == 200, "is answered 200")
		_check(not bool(d["resumed"]),
			"and does NOT report resumed, so a caller hashing the result knows why")

	var got := _read(dest)
	_check(got == BODY,
		"and the file is the resource once, not its prefix twice",
		"got %d bytes, expected %d" % [got.length(), BODY.length()])
	_check(not FileAccess.file_exists(dest + ".resume"), "leaving no sibling behind")


func _test_resume_failure_preserves_partial() -> void:
	_group("a resume that fails mid-transfer")

	# The reason the staging file is worth its complexity: a resume that writes
	# straight into the partial destroys it on the way to failing, and the next
	# attempt has neither the bytes nor a way to know they are gone.
	var dest := _scratch("failed.bin")
	var have := 40
	_write(dest, BODY.substr(0, have))
	_mode = "error"

	var res := await _http.download_to_file(_url(), dest, have)

	_check(not res.ok, "fails")
	_check(_read(dest) == BODY.substr(0, have),
		"and the partial it was extending is byte-for-byte what it was",
		"%d bytes" % _read(dest).length())
	_check(not FileAccess.file_exists(dest + ".resume"),
		"and the staging file does not accumulate beside it")


func _test_range_not_satisfiable() -> void:
	_group("a resume the server answers 416")

	var dest := _scratch("over.bin")
	_write(dest, BODY)
	_mode = "416"

	var res := await _http.download_to_file(_url(), dest, BODY.length())

	_check(not res.ok, "fails rather than being taken for an empty success")
	if not res.ok:
		_check(res.error.code == DotError.CODE_INVALID,
			"with a code the caller can branch on", res.code())
	_check(_read(dest) == BODY, "and leaves the local file alone")
	_check(not FileAccess.file_exists(dest + ".resume"), "leaving no sibling behind")


# --- The filesystem primitive ----------------------------------------------

func _test_append_file() -> void:
	_group("DotPaths.append_file")

	var dest := _scratch("append.bin")
	var src := _scratch("append.src")

	_write(dest, "AAAA")
	_write(src, "BBBB")
	var res := DotPaths.append_file(dest, src)
	_check(res.ok and _read(dest) == "AAAABBBB", "appends at the end by default", _read(dest))

	# A partial longer than the offset that was requested. Without the truncate
	# the tail of the old content survives past the join and the file is a
	# splice of two attempts.
	_write(dest, "AAAAXXXXXXXX")
	_write(src, "BBBB")
	res = DotPaths.append_file(dest, src, 4)
	_check(res.ok and _read(dest) == "AAAABBBB",
		"truncates to the offset first, so stale bytes past the join cannot survive",
		_read(dest))

	_write(dest, "AAAA")
	res = DotPaths.append_file(dest, src, 99)
	_check(not res.ok, "refuses an offset past the end rather than punching a hole")
	if not res.ok:
		_check(res.error.code == DotError.CODE_INVALID, "with CODE_INVALID", res.code())
	_check(_read(dest) == "AAAA", "and leaves the destination untouched when it refuses")

	res = DotPaths.append_file(_scratch("nope.bin"), _scratch("missing.src"))
	_check(not res.ok, "reports a missing source instead of creating an empty file")

	# Bigger than one chunk, because the loop is the part that can drop bytes.
	var big := "z".repeat(300000)
	_write(dest, "AAAA")
	_write(src, big)
	res = DotPaths.append_file(dest, src, 4, 4096)
	_check(res.ok and DotPaths.file_size(dest) == 4 + big.length(),
		"streams a source larger than its chunk without losing any of it",
		"%d bytes" % DotPaths.file_size(dest))


func _test_replace_file() -> void:
	_group("DotPaths.replace_file")

	var dest := _scratch("replace.bin")
	var src := _scratch("replace.src")

	_write(dest, "old")
	_write(src, "new")

	var res := DotPaths.replace_file(dest, src)
	_check(res.ok, "succeeds over an existing destination",
		"" if res.ok else res.error.message)
	_check(_read(dest) == "new", "with the source's contents", _read(dest))
	_check(not FileAccess.file_exists(src), "and consumes the source")

	_write(src, "fresh")
	var absent := _scratch("replace_absent.bin")
	res = DotPaths.replace_file(absent, src)
	_check(res.ok and _read(absent) == "fresh", "and works when there is nothing to replace")


# --- The server ------------------------------------------------------------

func _listen() -> bool:
	for p in range(PORT_FIRST, PORT_LAST):
		if _server.listen(p, "127.0.0.1") == OK:
			_port = p
			return true
	return false


func _url() -> String:
	return "http://127.0.0.1:%d/content.bin" % _port


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		_clients.append(_server.take_connection())

	for c in _clients:
		c.poll()
		if c.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		if c.get_available_bytes() <= 0:
			continue
		var raw := c.get_utf8_string(c.get_available_bytes())
		if raw.strip_edges() == "":
			continue
		_answer(c, raw)


func _answer(c: StreamPeerTCP, raw: String) -> void:
	var range_header := ""
	for line in raw.split("\r\n"):
		if line.to_lower().begins_with("range:"):
			range_header = line.split(":", true, 1)[1].strip_edges()

	_requests.append({"range": range_header})

	var start := 0
	if range_header.begins_with("bytes="):
		start = int(range_header.substr(6).split("-")[0])

	var head := ""
	var body := ""

	match _mode:
		"error":
			head = "HTTP/1.1 500 Internal Server Error\r\n"
			body = "no"
		"416":
			head = "HTTP/1.1 416 Range Not Satisfiable\r\n"
			head += "Content-Range: bytes */%d\r\n" % BODY.length()
		"ignore-range":
			# Answering 200 to a Range request: legal, common, and the case a
			# naive append turns into a duplicated prefix.
			head = "HTTP/1.1 200 OK\r\n"
			body = BODY
		_:
			if start > 0:
				head = "HTTP/1.1 206 Partial Content\r\n"
				head += "Content-Range: bytes %d-%d/%d\r\n" % [
					start, BODY.length() - 1, BODY.length()
				]
				body = BODY.substr(start)
			else:
				head = "HTTP/1.1 200 OK\r\n"
				body = BODY

	head += "Accept-Ranges: bytes\r\n"
	head += "Content-Length: %d\r\n" % body.length()
	head += "Connection: close\r\n\r\n"

	c.put_data((head + body).to_utf8_buffer())
	c.disconnect_from_host()


# --- Scratch files ---------------------------------------------------------

func _scratch(name: String) -> String:
	DotPaths.ensure_dir("user://http_selftest")
	return "user://http_selftest".path_join(name)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


# --- Assertions ------------------------------------------------------------

func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


func _group(title: String) -> void:
	print("")
	print("%s" % title)
