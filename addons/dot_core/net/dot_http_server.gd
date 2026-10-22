class_name DotHttpServer
extends RefCounted

## A small HTTP/1.1 server on [TCPServer] for admin pages and JSON endpoints; the host calls [method poll] every frame.
##
## Desktop and dedicated server only ([method DotPlatform.can_listen]). One request per connection,
## no keep-alive, no chunked bodies, no pipelining, handlers run synchronously inside [method poll].
## It is strict: a malformed request gets 400, 408, 413, 414, 431, 501 or 505 and never reaches a route.

const CHANNEL := "http_server"
const LOOPBACK := "127.0.0.1"

## Largest request line plus headers.
var max_head_bytes := 8192
var max_request_line := 2048
var max_headers := 64
var max_body_bytes := 1048576
## Seconds from accept to a complete request, and again from response start to the last byte sent.
var read_timeout_sec := 10.0
var write_timeout_sec := 10.0
var max_connections := 64
## Largest file [method serve_dir] will send.
var max_static_bytes := 16777216

var requests := 0
var rejected := 0

var _server: TCPServer
var _tls_options: TLSOptions
var _conns: Array[Conn] = []
var _routes: Dictionary = {}
var _prefixes: Array[Dictionary] = []
var _bind := ""


class Conn:
	extends RefCounted
	var tcp: StreamPeerTCP
	var tls: StreamPeerTLS
	var stream: StreamPeer
	var buf := PackedByteArray()
	var scanned := 0
	var head: Dictionary = {}
	var head_end := -1
	var need := 0
	var out := PackedByteArray()
	var sent := 0
	var writing := false
	var head_only := false
	var started_msec := 0
	var write_started_msec := 0
	var remote := ""


## Binds and listens. Empty [param cert_path] and [param key_path] mean plain HTTP; give both for TLS.
## Paths only: key material is read from the files here and never from environment or argv.
func start(port: int, bind_address: String = LOOPBACK, cert_path: String = "", key_path: String = "") -> DotResult:
	if not DotPlatform.can_listen():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "an HTTP server cannot listen on this platform")
	if _server != null:
		return DotResult.fail(DotError.CODE_STATE, "already listening")
	if cert_path.is_empty() != key_path.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "TLS needs both a certificate path and a key path")
	_tls_options = null
	if not cert_path.is_empty():
		if not FileAccess.file_exists(cert_path) or not FileAccess.file_exists(key_path):
			return DotResult.fail(DotError.CODE_IO, "TLS certificate or key file missing", "%s, %s" % [cert_path, key_path])
		var cert := X509Certificate.new()
		if cert.load(cert_path) != OK:
			return DotResult.fail(DotError.CODE_IO, "cannot read TLS certificate", cert_path)
		var key := CryptoKey.new()
		if key.load(key_path) != OK:
			return DotResult.fail(DotError.CODE_IO, "cannot read TLS key", key_path)
		_tls_options = TLSOptions.server(key, cert)
	var srv := TCPServer.new()
	var err := srv.listen(port, bind_address)
	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "listen %s:%d" % [bind_address, port]))
	_server = srv
	_bind = bind_address
	if _tls_options == null and not is_loopback(bind_address):
		DotLog.warn(CHANNEL, "plain HTTP on a non-loopback address; put TLS in front", {"bind": bind_address})
	DotLog.info(CHANNEL, "listening", {"bind": bind_address, "port": srv.get_local_port(), "tls": _tls_options != null})
	return DotResult.success(srv.get_local_port())


## Applies a config dictionary: bind, port, tls_mode ("native" uses cert and key paths), cert, key.
func start_from_config(cfg: Dictionary) -> DotResult:
	var native := str(cfg.get("tls_mode", "proxy")) == "native"
	return start(int(cfg.get("port", 8080)), str(cfg.get("bind", LOOPBACK)),
		str(cfg.get("cert", "")) if native else "", str(cfg.get("key", "")) if native else "")


func stop() -> void:
	for c in _conns:
		_close(c)
	_conns.clear()
	if _server != null:
		_server.stop()
		DotLog.info(CHANNEL, "stopped", {"requests": requests, "rejected": rejected})
	_server = null


func is_listening() -> bool:
	return _server != null and _server.is_listening()


func port() -> int:
	return _server.get_local_port() if _server != null else 0


## Registers an exact route. [param handler] is Callable(DotHttpRequest) -> DotHttpResponse. HEAD uses the GET route.
func route(method: String, path: String, handler: Callable) -> void:
	_routes["%s %s" % [method.to_upper(), path]] = handler


## Registers a handler for every path under [param prefix] (matched on whole segments; the remainder is request.rest).
func route_prefix(method: String, prefix: String, handler: Callable) -> void:
	_prefixes.append({"method": method.to_upper(), "prefix": prefix.rstrip("/"), "handler": handler})


## Serves files from [param dir] (res:// or user://) under [param url_prefix]. Traversal and dotfiles are refused.
func serve_dir(url_prefix: String, dir: String, index: String = "index.html") -> void:
	route_prefix("GET", url_prefix, func(req: DotHttpRequest) -> DotHttpResponse: return static_response(dir, req.rest, index, max_static_bytes))


## The file response for [param rel] under [param dir]: 403 for any traversal, 404 for missing, hidden or a directory without index.
static func static_response(dir: String, rel: String, index: String = "index.html", max_bytes: int = 16777216) -> DotHttpResponse:
	if rel.contains("\\") or rel.contains(":"):
		return DotHttpResponse.error(403)
	var parts: PackedStringArray = []
	for seg in rel.split("/"):
		if seg == "..":
			return DotHttpResponse.error(403)
		if seg == "" or seg == ".":
			continue
		if seg.begins_with("."):
			return DotHttpResponse.error(404)
		parts.append(seg)
	var path := dir.rstrip("/")
	if not parts.is_empty():
		path += "/" + "/".join(parts)
	if DirAccess.dir_exists_absolute(path):
		path += "/" + index
	if not FileAccess.file_exists(path):
		return DotHttpResponse.error(404)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return DotHttpResponse.error(404)
	if f.get_length() > max_bytes:
		return DotHttpResponse.error(403, "file too large")
	return DotHttpResponse.make(200, f.get_buffer(f.get_length()), content_type_for(path))


static func content_type_for(path: String) -> String:
	match path.get_extension().to_lower():
		"html", "htm": return "text/html; charset=utf-8"
		"css": return "text/css; charset=utf-8"
		"js", "mjs": return "text/javascript; charset=utf-8"
		"json": return "application/json; charset=utf-8"
		"txt", "md": return "text/plain; charset=utf-8"
		"svg": return "image/svg+xml"
		"png": return "image/png"
		"jpg", "jpeg": return "image/jpeg"
		"webp": return "image/webp"
		"ico": return "image/x-icon"
		"wasm": return "application/wasm"
	return "application/octet-stream"


## Reads a one-line secret (token) from a file; the only way a secret should reach the server's host.
static func read_secret_file(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_IO, "secret file missing", path)
	var text := FileAccess.get_file_as_string(path).strip_edges()
	if text.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "secret file is empty", path)
	return DotResult.success(text)


static func is_loopback(address: String) -> bool:
	return address == "127.0.0.1" or address == "::1" or address == "localhost" or address.begins_with("127.")


## Accepts, reads, dispatches and writes for every connection; call from the host's _process.
func poll() -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var tcp := _server.take_connection()
		if tcp == null:
			break
		_accept(tcp)
	var i := 0
	while i < _conns.size():
		var c := _conns[i]
		if _step(c):
			i += 1
		else:
			_close(c)
			_conns.remove_at(i)


func describe() -> Dictionary:
	return {
		"listening": is_listening(), "bind": _bind, "port": port(), "tls": _tls_options != null,
		"connections": _conns.size(), "requests": requests, "rejected": rejected,
		"routes": _routes.size() + _prefixes.size(),
		"limits": {"head": max_head_bytes, "body": max_body_bytes, "read_sec": read_timeout_sec, "connections": max_connections},
	}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray(["http server %s:%d tls=%s connections=%d requests=%d rejected=%d" % [
		d["bind"], d["port"], d["tls"], d["connections"], d["requests"], d["rejected"]]])


## Parses a request line and headers (no body). Value: {ok, method, path, query, headers} or {ok: false, status, detail}.
static func parse_head(head: String, p_max_line: int = 2048, p_max_headers: int = 64) -> Dictionary:
	for k in head.length():
		var ch := head.unicode_at(k)
		if ch > 126 or (ch < 32 and ch != 13 and ch != 10 and ch != 9):
			return _bad(400, "illegal character in head")
	var lines := head.split("\r\n")
	for ln in lines:
		if ln.contains("\n") or ln.contains("\r"):
			return _bad(400, "bare line break")
	var rl: String = lines[0]
	if rl.length() > p_max_line:
		return _bad(414, "request line too long")
	var parts := rl.split(" ")
	if parts.size() != 3:
		return _bad(400, "malformed request line")
	var method := parts[0]
	if method.is_empty() or method.length() > 16 or not _is_token(method) or method != method.to_upper():
		return _bad(400, "bad method")
	var version := parts[2]
	if not version.begins_with("HTTP/"):
		return _bad(400, "not HTTP")
	if version != "HTTP/1.1" and version != "HTTP/1.0":
		return _bad(505, "only HTTP/1.0 and 1.1")
	var target := parts[1]
	if not target.begins_with("/") or target.begins_with("//"):
		return _bad(400, "target must be an absolute path")
	var path_raw := target
	var query_raw := ""
	var q := target.find("?")
	if q >= 0:
		path_raw = target.substr(0, q)
		query_raw = target.substr(q + 1)
	var hash_at := query_raw.find("#")
	if hash_at >= 0:
		query_raw = query_raw.substr(0, hash_at)
	var path := percent_decode(path_raw)
	if path.is_empty():
		return _bad(400, "bad percent-encoding in path")
	for k in path.length():
		var ch := path.unicode_at(k)
		if ch < 32 or ch == 127:
			return _bad(400, "control character in path")
	var query := {}
	if not query_raw.is_empty():
		for pair in query_raw.split("&", false):
			var eq := pair.find("=")
			var key := percent_decode((pair if eq < 0 else pair.substr(0, eq)).replace("+", " "))
			var val := "" if eq < 0 else percent_decode(pair.substr(eq + 1).replace("+", " "))
			if key.is_empty() and not pair.begins_with("="):
				return _bad(400, "bad percent-encoding in query")
			query[key] = val
	var headers := {}
	if lines.size() - 1 > p_max_headers:
		return _bad(431, "too many headers")
	for n in range(1, lines.size()):
		var ln: String = lines[n]
		if ln.is_empty() or ln.begins_with(" ") or ln.begins_with("\t"):
			return _bad(400, "empty or folded header line")
		var colon := ln.find(":")
		if colon <= 0:
			return _bad(400, "header without a name")
		var name := ln.substr(0, colon)
		if not _is_token(name):
			return _bad(400, "bad header name")
		var key := name.to_lower()
		var val := ln.substr(colon + 1).strip_edges()
		if headers.has(key):
			if key == "content-length" and headers[key] != val:
				return _bad(400, "conflicting Content-Length")
			headers[key] = str(headers[key]) + ", " + val if key != "content-length" else val
		else:
			headers[key] = val
	return {"ok": true, "method": method, "path": path, "query": query, "headers": headers}


## Decodes %XX as UTF-8 bytes; returns "" for a malformed escape or an encoded NUL (the engine's uri_decode drops them silently).
static func percent_decode(s: String) -> String:
	if not s.contains("%"):
		return s
	var src := s.to_utf8_buffer()
	var out := PackedByteArray()
	var i := 0
	while i < src.size():
		if src[i] == 37:
			if i + 2 >= src.size():
				return ""
			var h := _hex(src[i + 1])
			var l := _hex(src[i + 2])
			if h < 0 or l < 0 or (h == 0 and l == 0):
				return ""
			out.append(h * 16 + l)
			i += 3
		else:
			out.append(src[i])
			i += 1
	return out.get_string_from_utf8()


static func _hex(b: int) -> int:
	if b >= 48 and b <= 57:
		return b - 48
	if b >= 97 and b <= 102:
		return b - 87
	if b >= 65 and b <= 70:
		return b - 55
	return -1


static func _bad(status: int, detail: String) -> Dictionary:
	return {"ok": false, "status": status, "detail": detail}


static func _is_token(s: String) -> bool:
	for k in s.length():
		var ch := s.unicode_at(k)
		var ok := (ch >= 48 and ch <= 57) or (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or "!#$%&'*+-.^_`|~".contains(s[k])
		if not ok:
			return false
	return true


func _accept(tcp: StreamPeerTCP) -> void:
	var c := Conn.new()
	c.tcp = tcp
	c.remote = tcp.get_connected_host()
	c.started_msec = Time.get_ticks_msec()
	tcp.set_no_delay(true)
	if _tls_options != null:
		c.tls = StreamPeerTLS.new()
		if c.tls.accept_stream(tcp, _tls_options) != OK:
			tcp.disconnect_from_host()
			return
		c.stream = c.tls
	else:
		c.stream = tcp
	if _conns.size() >= max_connections:
		rejected += 1
		_respond(c, DotHttpResponse.error(503, "too many connections"))
	_conns.append(c)


# True while the connection should stay in the table.
func _step(c: Conn) -> bool:
	var now := Time.get_ticks_msec()
	if c.tls != null:
		c.tls.poll()
		var ts := c.tls.get_status()
		if ts == StreamPeerTLS.STATUS_ERROR or ts == StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH or ts == StreamPeerTLS.STATUS_DISCONNECTED:
			return false
		if ts == StreamPeerTLS.STATUS_HANDSHAKING:
			return float(now - c.started_msec) / 1000.0 <= read_timeout_sec
	else:
		c.tcp.poll()
		if c.tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return false
	if c.writing:
		return _write(c, now)
	if float(now - c.started_msec) / 1000.0 > read_timeout_sec:
		return _reject(c, 408, "request not completed in time")
	var avail := c.stream.get_available_bytes()
	if avail > 0:
		var room := max_head_bytes + max_body_bytes + 4 - c.buf.size()
		var got: Array = c.stream.get_partial_data(mini(avail, maxi(room, 1)))
		if int(got[0]) != OK:
			return false
		c.buf.append_array(got[1] as PackedByteArray)
		_parse(c)
	if c.writing:
		return _write(c, now)
	return true


func _parse(c: Conn) -> void:
	if c.head_end < 0:
		var i := maxi(c.scanned - 3, 0)
		var n := c.buf.size()
		while i + 3 < n:
			if c.buf[i] == 13 and c.buf[i + 1] == 10 and c.buf[i + 2] == 13 and c.buf[i + 3] == 10:
				c.head_end = i
				break
			i += 1
		c.scanned = n
		if c.head_end < 0:
			if c.buf.size() > max_head_bytes:
				_reject(c, 431, "head too large")
			elif c.buf.find(10) < 0 and c.buf.size() > max_request_line:
				_reject(c, 414, "request line too long")
			return
		if c.head_end > max_head_bytes:
			_reject(c, 431, "head too large")
			return
		var raw := c.buf.slice(0, c.head_end)
		for b in raw:
			if b == 0 or b > 126 or (b < 32 and b != 13 and b != 10 and b != 9):
				_reject(c, 400, "illegal byte in head")
				return
		var head := raw.get_string_from_ascii()
		var parsed := parse_head(head, max_request_line, max_headers)
		if not bool(parsed["ok"]):
			_reject(c, int(parsed["status"]), str(parsed["detail"]))
			return
		var h: Dictionary = parsed["headers"]
		if h.has("transfer-encoding"):
			_reject(c, 501, "Transfer-Encoding is not supported")
			return
		if h.has("content-length"):
			var cl := str(h["content-length"])
			if cl.is_empty() or not cl.is_valid_int() or cl.begins_with("-") or cl.begins_with("+") or cl.length() > 12:
				_reject(c, 400, "bad Content-Length")
				return
			c.need = int(cl)
			if c.need > max_body_bytes:
				_reject(c, 413, "body too large")
				return
		elif str(parsed["method"]) in ["POST", "PUT", "PATCH"]:
			_reject(c, 411, "Content-Length required")
			return
		c.head = parsed
	var have := c.buf.size() - (c.head_end + 4)
	if have > c.need and c.need >= 0 and have > max_body_bytes:
		_reject(c, 413, "body too large")
		return
	if have >= c.need:
		_dispatch(c, c.buf.slice(c.head_end + 4, c.head_end + 4 + c.need))


func _dispatch(c: Conn, body: PackedByteArray) -> void:
	requests += 1
	var req := DotHttpRequest.new()
	req.method = str(c.head["method"])
	req.path = str(c.head["path"])
	req.query = c.head["query"]
	req.headers = c.head["headers"]
	req.body = body
	req.remote_address = c.remote
	c.head_only = req.method == "HEAD"
	var res := _route(req)
	DotLog.debug(CHANNEL, "request", {"method": req.method, "path": req.path, "status": res.status, "from": c.remote})
	_respond(c, res)


func _route(req: DotHttpRequest) -> DotHttpResponse:
	var method := "GET" if req.method == "HEAD" else req.method
	var handler := Callable()
	var key := "%s %s" % [method, req.path]
	if _routes.has(key):
		handler = _routes[key]
	else:
		var best := -1
		for p in _prefixes:
			var pre: String = p["prefix"]
			if p["method"] != method:
				continue
			if req.path == pre or req.path.begins_with(pre + "/") or pre.is_empty():
				if pre.length() > best:
					best = pre.length()
					handler = p["handler"]
					req.rest = req.path.substr(pre.length()).lstrip("/")
	if not handler.is_valid():
		var allowed := _allowed(req.path)
		if allowed.is_empty():
			return DotHttpResponse.error(404)
		var r := DotHttpResponse.error(405)
		r.headers["Allow"] = ", ".join(allowed)
		return r
	var out: Variant = handler.call(req)
	if out is DotHttpResponse:
		return out
	DotLog.error(CHANNEL, "handler returned no response", {"path": req.path})
	return DotHttpResponse.error(500)


func _allowed(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for k in _routes:
		var sp := str(k).find(" ")
		if str(k).substr(sp + 1) == path:
			out.append(str(k).substr(0, sp))
	for p in _prefixes:
		var pre: String = p["prefix"]
		if (path == pre or path.begins_with(pre + "/")) and not out.has(p["method"]):
			out.append(p["method"])
	return out


func _reject(c: Conn, status: int, detail: String) -> bool:
	rejected += 1
	DotLog.debug(CHANNEL, "rejected", {"status": status, "detail": detail, "from": c.remote})
	_respond(c, DotHttpResponse.error(status, detail))
	return true


func _respond(c: Conn, res: DotHttpResponse) -> void:
	c.out = res.to_wire(c.head_only)
	c.sent = 0
	c.writing = true
	c.write_started_msec = Time.get_ticks_msec()


func _write(c: Conn, now: int) -> bool:
	if float(now - c.write_started_msec) / 1000.0 > write_timeout_sec:
		return false
	if c.sent < c.out.size():
		var r: Array = c.stream.put_partial_data(c.out.slice(c.sent))
		if int(r[0]) != OK:
			return false
		c.sent += int(r[1])
	return c.sent < c.out.size()


func _close(c: Conn) -> void:
	if c.tls != null:
		c.tls.disconnect_from_stream()
	if c.tcp != null:
		c.tcp.disconnect_from_host()
