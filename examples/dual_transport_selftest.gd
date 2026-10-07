extends Node

## Exercises [DotTransportDual]: a WebSocket client and an ENet client on one server,
## a query datagram on the same UDP port, and the routing between them.
##
## Real sockets on loopback, real ENet and WebSocket peers — the point of the class is
## the seam between two engine peers, and a mock of either would only test the mock.
##
## [codeblock]
## godot --headless --path . res://examples/dual_transport_selftest.tscn
## [/codeblock]

const SECTIONS := 6
const CHECKS := 28

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


func _ready() -> void:
	DotLog.set_level(DotLog.Level.DEBUG if OS.get_environment("DUAL_DEBUG") != "" else DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-core dual transport self-test")
	_line("")

	if not ClassDB.class_exists("ENetMultiplayerPeer"):
		_line("ERROR: this build has no ENet; the suite needs it.")
		get_tree().quit(1)
		return

	await _test_listen()
	await _test_both_clients_join()
	await _test_routing()
	await _test_query_on_shared_port()
	await _test_disconnect_closes_relay()
	await _test_enet_port_busy_degrades()

	if _server != null:
		_server.close()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _test_listen() -> void:
	_section("One listen, two backends, one public UDP port")

	_transport = DotTransportDual.new()
	_transport.max_clients = 8
	var res := _transport.create_server(PORT, "127.0.0.1")
	_check(res.ok, "the server listens")
	if not res.ok:
		return

	_server = res.value as DotDualPeer
	_check(_server != null and _server.websocket != null and _server.enet != null, "both backends are up")
	_check(_transport.advertised_enet_port() == PORT, "ENet is advertised on the game port number")
	_check(_server.demux != null and _server.demux.public_port() == PORT, "the demux owns UDP %d" % PORT)
	_check(_transport.supports_web_clients(), "browsers can still join")

	_server.peer_connected.connect(func(id: int) -> void: _connected_ids.append(id))
	_server.peer_disconnected.connect(func(id: int) -> void: _disconnected_ids.append(id))
	await get_tree().process_frame


func _test_both_clients_join() -> void:
	_section("A WebSocket client and an ENet client join the same server")

	var ws_t := DotTransportWebSocket.new()
	var ws_res := ws_t.create_client("ws://127.0.0.1:%d" % PORT)
	var en_t := DotTransportENet.new()
	var en_res := en_t.create_client("127.0.0.1", PORT)
	_check(ws_res.ok and en_res.ok, "both clients are created")
	if not (ws_res.ok and en_res.ok):
		return
	_ws = ws_res.value
	_en = en_res.value

	await _pump_until(func() -> bool: return _connected_ids.size() >= 2)
	_check(_connected_ids.size() == 2, "the server saw two peers join")

	var ws_id := _ws.get_unique_id()
	var en_id := _en.get_unique_id()
	_check(_server.backend_name(ws_id) == "websocket", "the browser-shaped client is on WebSocket")
	_check(_server.backend_name(en_id) == "enet", "the native client is on ENet")
	_check(_server.get_peer_address(en_id) == "127.0.0.1", "the ENet peer's address is the client's, not the relay's")
	_check(
		_server.get_peer_port(en_id) == int(_en.call("get_host").call("get_local_port")),
		"and its port is the client's own socket, which ENet behind the relay never sees"
	)
	_check(_server.get_peer_address(ws_id) == "127.0.0.1", "the WebSocket peer has an address too")


func _test_routing() -> void:
	_section("Targeted, broadcast and exclude reach the right backend")
	if _ws == null or _en == null:
		return

	var ws_id := _ws.get_unique_id()
	var en_id := _en.get_unique_id()

	_server.set_target_peer(en_id)
	_server.put_packet("to-enet".to_utf8_buffer())
	_server.set_target_peer(ws_id)
	_server.put_packet("to-ws".to_utf8_buffer())
	_server.set_target_peer(0)
	_server.put_packet("to-all".to_utf8_buffer())
	_server.set_target_peer(-en_id)
	_server.put_packet("not-enet".to_utf8_buffer())

	var got_ws: Array[String] = []
	var got_en: Array[String] = []
	await _pump_until(func() -> bool:
		_collect(_ws, got_ws)
		_collect(_en, got_en)
		return got_ws.size() >= 3 and got_en.size() >= 2
	)
	await _pump_frames(5)
	_collect(_ws, got_ws)
	_collect(_en, got_en)

	_check(str(got_en) == str(["to-enet", "to-all"]), "ENet got its own and the broadcast (%s)" % [got_en])
	_check(str(got_ws) == str(["to-ws", "to-all", "not-enet"]), "WebSocket got its own, the broadcast and the exclude (%s)" % [got_ws])

	_en.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	_en.transfer_channel = 1
	_en.set_target_peer(1)
	_en.put_packet("from-enet".to_utf8_buffer())
	_ws.set_target_peer(1)
	_ws.put_packet("from-ws".to_utf8_buffer())

	var seen := {}
	await _pump_until(func() -> bool:
		while _server.get_available_packet_count() > 0:
			var from := _server.get_packet_peer()
			var channel := _server.get_packet_channel()
			var text := _server.get_packet().get_string_from_utf8()
			seen[text] = [from, channel]
		return seen.size() >= 2
	)
	_check(seen.get("from-enet", [0])[0] == en_id, "the server hears the ENet client as itself")
	_check(seen.get("from-enet", [0, -1])[1] == 1, "on the channel it sent on")
	_check(seen.get("from-ws", [0])[0] == ws_id, "and the WebSocket client as itself")


func _test_query_on_shared_port() -> void:
	_section("A connectionless query on the game port goes to its handler, not to ENet")

	var claim := func(data: PackedByteArray) -> bool:
		return data.size() >= 5 and data.decode_u32(0) == 0xFFFFFFFF
	var handle := func(data: PackedByteArray, _ip: String, _port: int) -> Array[PackedByteArray]:
		var reply := PackedByteArray([0xFF, 0xFF, 0xFF, 0xFF])
		reply.append_array("pong".to_utf8_buffer())
		return [reply] as Array[PackedByteArray]

	_check(_transport.add_datagram_handler(PORT, claim, handle), "a handler registers on the shared port")
	_check(not _transport.add_datagram_handler(PORT + 1, claim, handle), "and not on a port the demux does not own")

	var q := PacketPeerUDP.new()
	q.bind(0, "127.0.0.1")
	q.set_dest_address("127.0.0.1", PORT)
	var ask := PackedByteArray([0xFF, 0xFF, 0xFF, 0xFF, 0x54])
	q.put_packet(ask)

	# A lambda captures a local by value, so the answer goes into an array it shares.
	var answers: Array[PackedByteArray] = []
	await _pump_until(func() -> bool:
		if q.get_available_packet_count() > 0:
			answers.append(q.get_packet())
		return not answers.is_empty()
	)
	var answer: PackedByteArray = answers[0] if not answers.is_empty() else PackedByteArray()
	_check(answer.slice(4).get_string_from_utf8() == "pong", "the query was answered")

	var relays_before := _server.demux.relay_count()
	q.put_packet(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	await _pump_frames(5)
	_check(_server.demux.relay_count() == relays_before, "noise from a stranger opens no relay")
	_check(DotUdpDemux.is_enet_connect(PackedByteArray([0x7F, 0xFF, 0, 0])), "an unassigned ENet header reads as a connect")
	q.close()


func _test_disconnect_closes_relay() -> void:
	_section("An ENet client leaving closes its relay")
	if _en == null:
		return

	var en_id := _en.get_unique_id()
	_check(_server.demux.relay_count() == 1, "one relay for one ENet client")
	_en.close()
	_en = null
	await _pump_until(func() -> bool: return _disconnected_ids.has(en_id), 8.0)
	_check(_disconnected_ids.has(en_id), "the server saw the ENet client leave")
	_check(_server.demux.relay_count() == 0, "and its relay is gone")
	_check(_server.peer_counts() == {"websocket": 1, "enet": 0}, "the WebSocket client is still there")


func _test_enet_port_busy_degrades() -> void:
	_section("A busy UDP port costs ENet, not the server")

	var squatter := PacketPeerUDP.new()
	squatter.bind(PORT + 10, "127.0.0.1")
	var t := DotTransportDual.new()
	var res := t.create_server(PORT + 10, "127.0.0.1")
	_check(res.ok, "the server still listens")
	_check(not t.serves_enet() and t.advertised_enet_port() == 0, "without ENet, and it says so")
	if res.ok:
		(res.value as MultiplayerPeer).close()
	squatter.close()


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
