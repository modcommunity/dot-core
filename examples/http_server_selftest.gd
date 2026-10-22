extends Node

## Exercises DotHttpServer against real loopback sockets: parsing, routing, limits, traversal, JSON, bad input, DotHttp and TLS.
##
## [codeblock]
## godot --headless --path . res://examples/http_server_selftest.tscn
## [/codeblock]

const SECTIONS := 8
const CHECKS := 63
const SCRATCH := "user://http_server_selftest"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _srv: DotHttpServer
var _live := true
var _active: DotHttpServer


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	print("dot-core HTTP server self-test")
	DotPaths.remove_tree(SCRATCH)
	DotPaths.ensure_dir(SCRATCH + "/www/sub")
	_write(SCRATCH + "/www/index.html", "<h1>hi</h1>")
	_write(SCRATCH + "/www/sub/a.txt", "alpha")
	_write(SCRATCH + "/www/.secret", "hidden")
	_write(SCRATCH + "/outside.txt", "outside")
	_srv = DotHttpServer.new()
	_srv.route("GET", "/hello", func(_r: DotHttpRequest) -> DotHttpResponse: return DotHttpResponse.text(200, "world"))
	_srv.route("POST", "/echo", func(r: DotHttpRequest) -> DotHttpResponse: return DotHttpResponse.json({"len": r.body.size(), "q": r.query, "ua": r.header("User-Agent")}))
	_srv.route("GET", "/boom", func(_r: DotHttpRequest) -> DotHttpResponse: return null)
	_srv.route("GET", "/token", func(r: DotHttpRequest) -> DotHttpResponse: return DotHttpResponse.text(200, r.bearer_token()))
	_srv.route_prefix("GET", "/files/x", func(r: DotHttpRequest) -> DotHttpResponse: return DotHttpResponse.text(200, "x:" + r.rest))
	_srv.route_prefix("GET", "/files", func(r: DotHttpRequest) -> DotHttpResponse: return DotHttpResponse.text(200, "f:" + r.rest))
	_srv.serve_dir("/static", SCRATCH + "/www")
	var res := _srv.start(0)
	if not res.ok:
		print("  FAIL  cannot listen: %s" % res.error.message)
		get_tree().quit(1)
		return
	await _run()


func _process(_d: float) -> void:
	if _live and _srv != null:
		_srv.poll()


func _run() -> void:
	_live = false
	_section("parsing"); _test_parsing(); _done()
	_section("routing"); _test_routing(); _done()
	_section("limits"); _test_limits(); _done()
	_section("traversal"); _test_traversal(); _done()
	_section("json and response"); _test_json(); _done()
	_section("bad input"); _test_bad_input(); _done()
	_live = true
	_section("DotHttp client"); await _test_client(); _done()
	_section("tls"); await _test_tls(); _done()
	_live = false
	_srv.stop()
	DotPaths.remove_tree(SCRATCH)
	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [_passed, _failed, _completed, _entered])
	if _entered != SECTIONS or _completed != _entered or _passed + _failed != CHECKS:
		print("ERROR: %d sections and %d checks ran; expected %d and %d." % [_entered, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(n: String) -> void:
	_entered += 1
	print("[%s]" % n)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL  " + what)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


# One raw exchange: sends bytes, polls the server and reads until it closes or [param wait_sec] passes.
func _raw(data: PackedByteArray, wait_sec: float = 3.0, port: int = 0) -> String:
	var c := StreamPeerTCP.new()
	c.connect_to_host("127.0.0.1", port if port > 0 else _srv.port())
	var out := PackedByteArray()
	var sent := data.is_empty()
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < wait_sec:
		c.poll()
		if not sent and c.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			c.put_data(data)
			sent = true
		(_active if _active != null else _srv).poll()
		c.poll()
		if c.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var n := c.get_available_bytes()
			if n > 0:
				out.append_array(c.get_data(n)[1])
		if c.get_status() == StreamPeerTCP.STATUS_NONE or c.get_status() == StreamPeerTCP.STATUS_ERROR:
			break
		OS.delay_msec(1)
	c.disconnect_from_host()
	return out.get_string_from_utf8()


func _fetch(path: String, extra: String = "") -> String:
	return _raw(("GET %s HTTP/1.1\r\nHost: x\r\n%s\r\n" % [path, extra]).to_utf8_buffer())


func _status(resp: String) -> int:
	var parts := resp.split(" ", true, 2)
	return int(parts[1]) if parts.size() > 1 else -1


func _body(resp: String) -> String:
	var i := resp.find("\r\n\r\n")
	return resp.substr(i + 4) if i >= 0 else ""


func _test_parsing() -> void:
	var p := DotHttpServer.parse_head("GET /a%20b/c?x=1&y=hello+w%21&flag HTTP/1.1\r\nHost: h\r\nX-Multi: a\r\nx-multi: b\r\nAuthorization: Bearer tok")
	_check(bool(p["ok"]) and p["method"] == "GET", "request line parses")
	_check(p["path"] == "/a b/c", "path is percent-decoded")
	_check(p["query"] == {"x": "1", "y": "hello w!", "flag": ""}, "query decoded: %s" % str(p["query"]))
	_check(p["headers"]["host"] == "h" and p["headers"]["x-multi"] == "a, b", "headers lower-cased and joined")
	_check(DotHttpServer.parse_head("GET / HTTP/1.0")["ok"] == true, "HTTP/1.0 accepted")
	_check(int(DotHttpServer.parse_head("GET / HTTP/2.0")["status"]) == 505, "HTTP/2.0 is 505")
	_check(int(DotHttpServer.parse_head("GET /" + char(1) + " HTTP/1.1")["status"]) == 400, "control char is 400")
	_check(int(DotHttpServer.parse_head("GET /%00 HTTP/1.1")["status"]) == 400, "encoded NUL is 400")
	_check(int(DotHttpServer.parse_head("get / HTTP/1.1")["status"]) == 400, "lower-case method is 400")
	_check(int(DotHttpServer.parse_head("GET http://h/ HTTP/1.1")["status"]) == 400, "absolute-form is 400")
	_check(int(DotHttpServer.parse_head("GET / HTTP/1.1\r\nBad Name: x")["status"]) == 400, "space in header name is 400")
	_check(int(DotHttpServer.parse_head("GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2")["status"]) == 400, "conflicting lengths are 400")


func _test_routing() -> void:
	var r := _fetch("/hello")
	_check(_status(r) == 200 and _body(r) == "world", "exact route")
	_check(_status(_fetch("/nope")) == 404, "unknown path is 404")
	var m := _raw("POST /hello HTTP/1.1\r\nContent-Length: 0\r\n\r\n".to_utf8_buffer())
	_check(_status(m) == 405 and m.contains("Allow: GET"), "wrong method is 405 with Allow")
	var h := _raw("HEAD /hello HTTP/1.1\r\n\r\n".to_utf8_buffer())
	_check(_status(h) == 200 and _body(h) == "" and h.contains("Content-Length: 5"), "HEAD uses GET without a body")
	_check(_body(_fetch("/files/a/b")) == "f:a/b", "prefix route rest")
	_check(_body(_fetch("/files/x/q")) == "x:q", "longest prefix wins")
	_check(_status(_fetch("/filesx")) == 404, "prefix matches whole segments only")
	_check(_status(_fetch("/boom")) == 500, "handler returning null is 500")
	_check(_body(_fetch("/token", "Authorization: Bearer abc123\r\n")) == "abc123", "bearer token read")


func _test_limits() -> void:
	var big := "GET / HTTP/1.1\r\nX: %s\r\n\r\n" % "a".repeat(9000)
	_check(_status(_raw(big.to_utf8_buffer())) == 431, "oversized head is 431")
	var line := "GET /%s HTTP/1.1\r\n\r\n" % "a".repeat(3000)
	_check(_status(_raw(line.to_utf8_buffer())) == 414, "long request line is 414")
	var many := "GET / HTTP/1.1\r\n"
	for i in 80:
		many += "H%d: v\r\n" % i
	_check(_status(_raw((many + "\r\n").to_utf8_buffer())) == 431, "too many headers is 431")
	_srv.max_body_bytes = 100
	var b := "POST /echo HTTP/1.1\r\nContent-Length: 101\r\n\r\n" + "a".repeat(101)
	_check(_status(_raw(b.to_utf8_buffer())) == 413, "body over the limit is 413")
	_srv.max_body_bytes = 1048576
	_check(_status(_raw("POST /echo HTTP/1.1\r\n\r\nabc".to_utf8_buffer())) == 411, "POST without length is 411")
	_check(_status(_raw("POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".to_utf8_buffer())) == 501, "chunked is 501")
	_srv.read_timeout_sec = 0.3
	_check(_status(_raw("GET / HTTP/1.1\r\nHost".to_utf8_buffer())) == 408, "stalled head is 408")
	_check(_status(_raw("POST /echo HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort".to_utf8_buffer())) == 408, "stalled body is 408")
	_check(_status(_raw(PackedByteArray())) == 408, "silent connection is 408")
	_srv.read_timeout_sec = 10.0


func _test_traversal() -> void:
	_check(_body(_fetch("/static/")) == "<h1>hi</h1>", "index served")
	_check(_body(_fetch("/static/sub/a.txt")) == "alpha", "nested file served")
	_check(_status(_fetch("/static/../outside.txt")) == 403, "dot-dot is 403")
	_check(_status(_fetch("/static/%2e%2e/outside.txt")) == 403, "encoded dot-dot is 403")
	_check(_status(_fetch("/static/sub/..%2f..%2foutside.txt")) == 403, "encoded slash traversal is 403")
	_check(_status(_fetch("/static/..%5coutside.txt")) == 403, "backslash traversal is 403")
	_check(_status(_fetch("/static/.secret")) == 404, "dotfile is hidden")
	_check(_status(_fetch("/static/missing.txt")) == 404, "missing file is 404")
	_check(DotHttpServer.static_response(SCRATCH + "/www", "/etc/passwd").status == 404, "absolute rel stays under dir")
	_check(DotHttpServer.static_response(SCRATCH + "/www", "C:/x").status == 403, "drive path is 403")
	_check(_fetch("/static/sub/a.txt").contains("text/plain"), "content type by extension")


func _test_json() -> void:
	var r := _raw("POST /echo?a=1 HTTP/1.1\r\nUser-Agent: t\r\nContent-Length: 7\r\n\r\n{\"k\":1}".to_utf8_buffer())
	var j: Variant = JSON.parse_string(_body(r))
	_check(_status(r) == 200 and r.contains("application/json"), "json response header")
	_check(j is Dictionary and int(j["len"]) == 7 and j["q"] == {"a": "1"} and j["ua"] == "t", "json body round trips")
	var req := DotHttpRequest.new()
	req.body = "{\"k\": [1, 2]}".to_utf8_buffer()
	var jr := req.json_body()
	_check(jr.ok and jr.value["k"].size() == 2, "request json_body")
	req.body = "{nope".to_utf8_buffer()
	_check(not req.json_body().ok, "bad json is a failed result")
	var resp := DotHttpResponse.json({"a": 1}, 201)
	resp.headers["X-Evil"] = "a\r\nInjected: 1"
	var wire := resp.to_wire().get_string_from_utf8()
	_check(wire.begins_with("HTTP/1.1 201 ") and not wire.contains("\r\nInjected:"), "header injection stripped")


func _test_bad_input() -> void:
	_check(_status(_raw("garbage\r\n\r\n".to_utf8_buffer())) == 400, "garbage is 400")
	_check(_status(_raw("GET / HTTP/1.1\r\nno colon here\r\n\r\n".to_utf8_buffer())) == 400, "header without colon is 400")
	_check(_status(_raw("GET / HTTP/1.1\r\nHost: x\nX: y\r\n\r\n".to_utf8_buffer())) == 400, "bare LF is 400")
	_check(_status(_raw(PackedByteArray([0, 1, 2, 255, 254, 13, 10, 13, 10]))) == 400, "binary junk is 400")
	_check(_status(_raw("POST /echo HTTP/1.1\r\nContent-Length: -1\r\n\r\n".to_utf8_buffer())) == 400, "negative length is 400")
	_check(_status(_raw("POST /echo HTTP/1.1\r\nContent-Length: abc\r\n\r\n".to_utf8_buffer())) == 400, "non-numeric length is 400")
	_check(_status(_fetch("/hello")) == 200, "still serving after bad input")
	var before := _srv.describe()["connections"] as int
	_raw("GET / HT".to_utf8_buffer(), 0.1)
	_check(_srv.describe_lines().size() == 1 and before >= 0, "describe works")
	var s2 := DotHttpServer.new()
	_check(s2.start(0, "127.0.0.1", "/nonexistent.crt", "").error.code == DotError.CODE_INVALID, "cert without key refused")
	_check(s2.start(0, "127.0.0.1", "/nonexistent.crt", "/nonexistent.key").error.code == DotError.CODE_IO, "missing cert refused")
	_check(not DotHttpServer.read_secret_file("/nonexistent.token").ok, "missing secret file fails")


func _test_client() -> void:
	var http := DotHttp.new()
	http.max_retries = 0
	http.base_url = "http://127.0.0.1:%d" % _srv.port()
	add_child(http)
	var res: DotResult = await http.get_bytes("/hello")
	_check(res.ok and (res.value as PackedByteArray).get_string_from_utf8() == "world", "DotHttp GET against the server")
	var res2: DotResult = await http.post_json("/echo", {"a": 1})
	_check(res2.ok, "DotHttp POST json")
	var res3: DotResult = await http.get_json("/nope")
	_check(not res3.ok, "DotHttp sees a 404 as failure")
	http.queue_free()


func _test_tls() -> void:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var cert := crypto.generate_self_signed_certificate(key, "CN=localhost")
	key.save(SCRATCH + "/k.key")
	cert.save(SCRATCH + "/c.crt")
	var s := DotHttpServer.new()
	s.route("GET", "/t", func(_r: DotHttpRequest) -> DotHttpResponse: return DotHttpResponse.text(200, "secure"))
	var started := s.start(0, "127.0.0.1", SCRATCH + "/c.crt", SCRATCH + "/k.key")
	_check(started.ok and s.describe()["tls"] == true, "TLS server starts from paths")
	if not started.ok:
		return
	var tcp := StreamPeerTCP.new()
	tcp.connect_to_host("127.0.0.1", s.port())
	var tls := StreamPeerTLS.new()
	var begun := false
	var out := PackedByteArray()
	var sent := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		tcp.poll()
		if not begun and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			tls.connect_to_stream(tcp, "localhost", TLSOptions.client_unsafe())
			begun = true
		s.poll()
		if begun:
			tls.poll()
			if tls.get_status() == StreamPeerTLS.STATUS_CONNECTED:
				if not sent:
					tls.put_data("GET /t HTTP/1.1\r\nHost: x\r\n\r\n".to_utf8_buffer())
					sent = true
				var n := tls.get_available_bytes()
				if n > 0:
					out.append_array(tls.get_data(n)[1])
			elif tls.get_status() == StreamPeerTLS.STATUS_ERROR:
				break
		if out.get_string_from_utf8().ends_with("secure"):
			break
		OS.delay_msec(1)
	var resp := out.get_string_from_utf8()
	_check(_status(resp) == 200 and resp.ends_with("secure"), "request over TLS: %s" % resp.left(40))
	_active = s
	var plain := _raw("GET /t HTTP/1.1\r\n\r\n".to_utf8_buffer(), 0.5, s.port())
	_check(plain == "", "plain HTTP at a TLS port gets no response")
	_active = null
	s.stop()
