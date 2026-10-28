extends Node

## Shared state, pumping helpers and the raw-socket sections of dual_transport_selftest.gd.

const PORT := 47391

var _passed := 0
var _failed := 0
var _section_count := 0

var _transport: DotTransportDual = null
var _server: DotDualPeer = null
var _ws: MultiplayerPeer = null
var _en: MultiplayerPeer = null
var _connected_ids: Array[int] = []
var _disconnected_ids: Array[int] = []


## Connects a client, has the server send it a reliable packet every 100 ms, and stops
## polling the client for eight seconds -- as a stalled process or a dead patch of wifi
## does -- then polls it for two more. Returns [dropped, why, received, sent].
func _quiet_client(server_transport: DotTransportENet, port: int) -> Array:
	var res := server_transport.create_server(port, "127.0.0.1")
	if not res.ok:
		return [true, "could not listen on %d" % port, 0, 0]
	var server := res.value as ENetMultiplayerPeer
	var lost := [false]
	var joined := [false]
	server.peer_disconnected.connect(func(_id: int) -> void: lost[0] = true)
	server.peer_connected.connect(func(_id: int) -> void: joined[0] = true)
	# A temporary transport, as most callers make one: the timeouts must still land after
	# it is gone.
	var client := DotTransportENet.new().create_client("127.0.0.1", port).value as ENetMultiplayerPeer
	var deadline := Time.get_ticks_msec() + 3000
	# Both ends: the client reports connected one step before the server has finished the
	# handshake, and a client that stopped polling there would leave the server with no peer
	# to time out at all.
	while not (joined[0] and client.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED) \
			and Time.get_ticks_msec() < deadline:
		server.poll()
		client.poll()
		OS.delay_msec(5)

	var sent := 0
	var got := 0
	var quiet_until := Time.get_ticks_msec() + 8000
	# Afterwards, until everything has arrived or twenty seconds: eight seconds of silence
	# has doubled ENet's resend interval to several seconds, so the backlog comes in late.
	var end := quiet_until + 20000
	var next_send := 0
	while Time.get_ticks_msec() < end and not (lost[0] and Time.get_ticks_msec() >= quiet_until) \
			and not (sent > 0 and got >= sent):
		var now := Time.get_ticks_msec()
		server.poll()
		if now >= next_send and not lost[0] and Time.get_ticks_msec() < quiet_until:
			server.set_target_peer(0)
			server.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
			server.put_packet(PackedByteArray([sent % 256]))
			sent += 1
			next_send = now + 100
		if now >= quiet_until:
			client.poll()
			while client.get_available_packet_count() > 0:
				client.get_packet()
				got += 1
		OS.delay_msec(5)
		if Time.get_ticks_msec() % 50 == 0:
			await get_tree().process_frame

	var back_in := Time.get_ticks_msec() - quiet_until
	client.close()
	server.close()
	return [lost[0], ("dropped" if lost[0] else "still connected, backlog in %.1f s" % (back_in / 1000.0)), got, sent]


# --- Helpers ---------------------------------------------------------------

func _poll_all() -> void:
	if _server != null:
		_server.poll()
	for p in [_ws, _en]:
		if p != null:
			p.poll()


func _pump_until(done: Callable, seconds: float = 5.0) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		_poll_all()
		if done.call():
			return
		await get_tree().process_frame


func _pump_frames(n: int) -> void:
	for i in n:
		_poll_all()
		await get_tree().process_frame


func _collect(peer: MultiplayerPeer, into: Array[String]) -> void:
	while peer.get_available_packet_count() > 0:
		into.append(peer.get_packet().get_string_from_utf8())



## A native client dials wss:// first; an unscreened plain listener sat on the ClientHello until the
## client's TLS timeout. The screen closes it at once; armed: with the screen off it stays open.
func _test_tls_hello_screened() -> void:
	_section("A TLS ClientHello at the plain WebSocket port is closed in a round trip")

	var port := PORT + 50
	_tls_auto_checks(port)
	var t := DotTransportDual.new()
	t.tls_hello_screen = DotTransportDual.TlsHelloScreen.ON
	var made := t.create_server(port, "127.0.0.1")
	var server := made.value as DotDualPeer if made.ok else null
	_check(server != null and server.screen != null, "on: a dual server listens with its TCP port screened")
	if server == null or server.screen == null:
		return

	var raw_ms := await _raw_hello_closed_ms(server, port)
	_check(raw_ms >= 0 and raw_ms < 1000, "a raw TLS handshake byte is closed in %d ms" % raw_ms)
	_check(int(server.screen.describe()["refused_tls"]) == 1, "and counted as a refused TLS hello")

	# The real thing: the engine's own wss:// client, as the client link's TLS-first try is.
	var wss := WebSocketMultiplayerPeer.new()
	var wss_err := wss.create_client("wss://127.0.0.1:%d/game" % port, TLSOptions.client_unsafe())
	var started := Time.get_ticks_msec()
	var failed := false
	while wss_err == OK and Time.get_ticks_msec() - started < 3000 and not failed:
		server.poll()
		wss.poll()
		failed = wss.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED
		await get_tree().process_frame
	var wss_ms := Time.get_ticks_msec() - started
	_check(failed and wss_ms < 1000, "a wss:// client at the plain port fails in %d ms, not at its timeout" % wss_ms)
	wss.close()

	var ids: Array[int] = []
	server.peer_connected.connect(func(id: int) -> void: ids.append(id))
	var ws := DotTransportWebSocket.new().create_client("ws://127.0.0.1:%d" % port).value as MultiplayerPeer
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and (ids.is_empty() or ws.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED):
		server.poll()
		ws.poll()
		await get_tree().process_frame
	_check(ids.size() == 1, "a plain WebSocket client still joins through the screen")
	if ids.is_empty():
		server.close()
		return
	await _tls_relay_checks(server, ws, ids[0])
	await _tls_control_checks(port)


func _tls_relay_checks(server: DotDualPeer, ws: MultiplayerPeer, id: int) -> void:
	var deadline := 0
	server.set_target_peer(id)
	server.put_packet("down".to_utf8_buffer())
	ws.set_target_peer(1)
	ws.put_packet("up".to_utf8_buffer())
	var got_client: Array[String] = []
	var got_server: Array[String] = []
	deadline = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and (got_client.is_empty() or got_server.is_empty()):
		server.poll()
		ws.poll()
		_collect(ws, got_client)
		_collect(server, got_server)
		await get_tree().process_frame
	_check(got_client == ["down"], "the server's packet reaches the client (%s)" % [got_client])
	_check(got_server == ["up"], "and the client's reaches the server (%s)" % [got_server])

	# 64 KiB both ways: more than one read of the relay, as a content chunk is.
	var big := PackedByteArray()
	big.resize(65000)
	for i in big.size():
		big[i] = i % 251
	server.set_target_peer(id)
	server.put_packet(big)
	var big_back := PackedByteArray()
	deadline = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and big_back.is_empty():
		server.poll()
		ws.poll()
		if ws.get_available_packet_count() > 0:
			big_back = ws.get_packet()
		await get_tree().process_frame
	_check(big_back == big, "a 65000-byte packet crosses the relay intact")

	var relay_port := int(server.websocket.call("get_peer_port", id))
	_check(server.get_peer_address(id) == "127.0.0.1", "the WebSocket peer's address is the client's")
	_check(
		server.get_peer_port(id) != relay_port and server.get_peer_port(id) > 0,
		"and its port is the client's (%d), not the relay's (%d)" % [server.get_peer_port(id), relay_port]
	)

	ws.close()
	deadline = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and (server.screen.link_count() > 0 or server.peer_counts()["websocket"] > 0):
		server.poll()
		await get_tree().process_frame
	_check(
		server.screen.link_count() == 0 and server.peer_counts()["websocket"] == 0,
		"the client leaving closes its link (%d link(s), %s)" % [server.screen.link_count(), server.peer_counts()]
	)
	server.close()


func _tls_control_checks(port: int) -> void:
	# The control: unscreened, the engine sits on the same hello.
	var plain_t := DotTransportDual.new()
	plain_t.tls_hello_screen = DotTransportDual.TlsHelloScreen.OFF
	var plain_made := plain_t.create_server(port + 1, "127.0.0.1")
	var plain := plain_made.value as DotDualPeer if plain_made.ok else null
	_check(plain != null and plain.screen == null, "off: no screen")
	if plain == null:
		return
	var plain_ms := await _raw_hello_closed_ms(plain, port + 1, 1000)
	_check(plain_ms < 0, "and the same hello is still open after a second (the bug this screens)")
	plain.close()


func _tls_auto_checks(port: int) -> void:
	var auto_made := DotTransportDual.new().create_server(port, "127.0.0.1")
	_check(
		auto_made.ok and (auto_made.value as DotDualPeer).screen != null,
		"auto: a loopback listener (behind a TLS terminator) is screened too, a proxied scanner reaches it"
	)
	if auto_made.ok:
		(auto_made.value as DotDualPeer).close()
	_check(
		DotTransportDual.is_loopback_bind("127.0.0.1") and DotTransportDual.is_loopback_bind("::1")
			and not DotTransportDual.is_loopback_bind("") and not DotTransportDual.is_loopback_bind("*")
			and not DotTransportDual.is_loopback_bind("0.0.0.0") and not DotTransportDual.is_loopback_bind("10.0.0.5"),
		"is_loopback_bind names loopback and nothing wider"
	)


## Collects the engine's own error output: a script cannot read stderr, but a [Logger] sees
## every engine error. Only wsl_peer's matter here.
class EngineErrors extends Logger:
	var wsl_peer: Array[String] = []

	func _log_error(
		_function: String, file: String, _line: int, code: String, rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array
	) -> void:
		if file.contains("wsl_peer"):
			wsl_peer.append(rationale if rationale != "" else code)


const _KEY := "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"


## A plain "GET /" with no Upgrade header must be answered and closed here, not reach the engine
## (which logs a wsl_peer ERROR nothing can lower). Armed: with the screen off the error is raised.
func _test_plain_http_screened() -> void:
	_section("A request the engine would reject never reaches it")
	var logger := EngineErrors.new()
	OS.add_logger(logger)
	var records: Array[Dictionary] = []
	var on_record := func(rec: Dictionary) -> void:
		if str(rec.get("channel", "")) == "transport":
			records.append(rec)
	DotLog.signals().record.connect(on_record)
	DotLog.set_level(DotLog.Level.DEBUG)

	var port := PORT + 60
	var t := DotTransportDual.new()
	t.tls_hello_screen = DotTransportDual.TlsHelloScreen.ON
	var made := t.create_server(port, "127.0.0.1")
	var server := made.value as DotDualPeer if made.ok else null
	_check(server != null and server.screen != null, "on: screened server listens")
	if server == null or server.screen == null:
		OS.remove_logger(logger)
		return
	var scan := "GET / HTTP/1.1\r\nHost: x\r\nUser-Agent: scan\r\nAccept: */*\r\n\r\n"
	var reply := await _raw_request(server, port, scan.to_utf8_buffer())
	_check(reply.begins_with("HTTP/1.1 426"), "a plain GET is answered 426 and closed (%s)" % reply.left(20).c_escape())
	_check(int(server.screen.describe()["refused_http"]) == 1, "and counted as a refused HTTP request")

	var ish := "GET /game HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n"
	reply = await _raw_request(server, port, ish.to_utf8_buffer())
	_check(reply.begins_with("HTTP/1.1 426"), "a websocket-ish request missing its key is refused too")
	var ish2 := "GET /game HTTP/1.1\r\nHost: x\r\nUpgrade: websocket-ish\r\nConnection: Upgrade\r\n" + _KEY + "Sec-WebSocket-Version: 13\r\n\r\n"
	reply = await _raw_request(server, port, ish2.to_utf8_buffer())
	_check(reply.begins_with("HTTP/1.1 426"), "and so is an Upgrade value that only contains websocket")

	reply = await _raw_request(server, port, ("GET / HTTP/1.1\r\nX: " + "a".repeat(5000) + "\r\n\r\n").to_utf8_buffer())
	_check(reply.begins_with("HTTP/1.1 431"), "a header over the engine's 4096 bytes is answered 431")

	var cut := await _raw_request(server, port, "GET /ga".to_utf8_buffer(), 7000)
	_check(cut == "" and int(server.screen.describe()["timed_out"]) == 1, "a truncated request is closed at the screen's timeout, not the engine's")

	# A handshake in odd case with a list-valued Connection, written in two pieces.
	var good := "GET /game HTTP/1.1\r\nHost: x\r\nUpgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\n" + _KEY + "Sec-WebSocket-Protocol: dot.v1\r\nSec-WebSocket-Version: 13\r\n\r\n"
	var whole := good.to_utf8_buffer()
	reply = await _raw_request(server, port, whole.slice(0, 40), 3000, whole.slice(40))
	_check(reply.begins_with("HTTP/1.1 101"), "a mixed-case handshake split across two writes is relayed and accepted (%s)" % reply.left(20).c_escape())

	var ids: Array[int] = []
	server.peer_connected.connect(func(id: int) -> void: ids.append(id))
	var ws := DotTransportWebSocket.new().create_client("ws://127.0.0.1:%d" % port).value as MultiplayerPeer
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and ids.is_empty():
		server.poll()
		ws.poll()
		await get_tree().process_frame
	_check(ids.size() == 1, "a real WebSocket client still joins")
	ws.close()
	_check(logger.wsl_peer.is_empty(), "on: the engine raised no wsl_peer error (%s)" % [logger.wsl_peer])
	var debug_lines := 0
	for rec in records:
		if int(rec.get("level", -1)) == DotLog.Level.DEBUG and (rec.get("fields", {}) as Dictionary).has("ip"):
			debug_lines += 1
	_check(debug_lines >= 4, "and each refusal left a DEBUG line with the address (%d)" % debug_lines)
	server.close()

	var off_t := DotTransportDual.new()
	off_t.tls_hello_screen = DotTransportDual.TlsHelloScreen.OFF
	var off_made := off_t.create_server(port + 1, "127.0.0.1")
	var off := off_made.value as DotDualPeer if off_made.ok else null
	_check(off != null and off.screen == null, "off: no screen")
	if off != null:
		await _raw_request(off, port + 1, scan.to_utf8_buffer(), 1500)
		_check(not logger.wsl_peer.is_empty(), "and unscreened the engine does raise its wsl_peer error (the bug this screens)")
		off.close()
	DotLog.signals().record.disconnect(on_record)
	DotLog.set_level(DotLog.Level.ERROR)
	OS.remove_logger(logger)


## Sends [param bytes] and returns what the server wrote back before closing or
## [param limit_ms] passed.
func _raw_request(server: DotDualPeer, port: int, bytes: PackedByteArray, limit_ms: int = 3000, second: PackedByteArray = PackedByteArray()) -> String:
	var tcp := StreamPeerTCP.new()
	tcp.connect_to_host("127.0.0.1", port)
	var deadline := Time.get_ticks_msec() + 2000
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		tcp.poll()
		server.poll()
		await get_tree().process_frame
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return "<no connection>"
	tcp.put_data(bytes)
	var got := PackedByteArray()
	var started := Time.get_ticks_msec()
	var frames := 0
	while Time.get_ticks_msec() - started < limit_ms:
		server.poll()
		tcp.poll()
		frames += 1
		if frames == 10 and not second.is_empty():
			tcp.put_data(second)
		# A relayed handshake leaves the connection open: its reply is complete at the blank line.
		if got.get_string_from_ascii().contains("\r\n\r\n"):
			break
		if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var n := tcp.get_available_bytes()
			if n > 0:
				got.append_array(tcp.get_data(n)[1])
		else:
			break
		await get_tree().process_frame
	tcp.disconnect_from_host()
	return got.get_string_from_ascii()


## Sends a TLS handshake record's first bytes and returns how long the server took to close
## the connection, or -1 when it was still open after [param limit_ms].
func _raw_hello_closed_ms(server: DotDualPeer, port: int, limit_ms: int = 3000) -> int:
	var tcp := StreamPeerTCP.new()
	tcp.connect_to_host("127.0.0.1", port)
	var deadline := Time.get_ticks_msec() + 2000
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		tcp.poll()
		server.poll()
		await get_tree().process_frame
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return -2
	# A ClientHello's record header: handshake, TLS 1.0 record version, a length; then the
	# start of the hello. No CRLF anywhere, as in a real one.
	tcp.put_data(PackedByteArray([0x16, 0x03, 0x01, 0x00, 0x2a, 0x01, 0x00, 0x00, 0x26, 0x03, 0x03]))
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < limit_ms:
		server.poll()
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			var took := Time.get_ticks_msec() - started
			tcp.disconnect_from_host()
			return took
		await get_tree().process_frame
	tcp.disconnect_from_host()
	return -1


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
