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

const SECTIONS := 14
const CHECKS := 95

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
	await _test_metered_clients()
	await _test_query_on_shared_port()
	await _test_disconnect_closes_relay()
	await _test_leaving_together()
	await _test_websocket_leaving()
	await _test_enet_port_busy_degrades()
	await _test_enet_server_bandwidth()
	await _test_enet_peer_timeout()
	await _test_shutdown_reaches_enet()
	await _test_tls_hello_screened()
	await _test_plain_http_screened()

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


## [DotMeteredPeer] behind a real [SceneMultiplayer], on both transports: what net_stat
## draws is only worth drawing if the wrapper is invisible to everything above it. The
## SceneMultiplayer half is the one that matters — it decides "connected" from the
## wrapper's status and its peer_connected(1), and a wrapper that got either wrong would
## be a client that never finishes connecting, with nothing in the log.
func _test_metered_clients() -> void:
	_section("A metered client is counted, and SceneMultiplayer cannot tell it is there")

	var before := _connected_ids.size()
	var ws_res := DotTransportWebSocket.new().create_client("ws://127.0.0.1:%d" % PORT)
	var en_res := DotTransportENet.new().create_client("127.0.0.1", PORT)
	if not (ws_res.ok and en_res.ok):
		_check(false, "both metered clients are created")
		return
	var ws := DotMeteredPeer.wrap(ws_res.value) as DotMeteredPeer
	var en := DotMeteredPeer.wrap(en_res.value) as DotMeteredPeer
	_check(DotMeteredPeer.wrap(ws) == ws, "wrapping a meter again is the same meter")

	var api := SceneMultiplayer.new()
	var joined := [false]
	api.connected_to_server.connect(func() -> void: joined[0] = true)
	api.multiplayer_peer = en
	await _pump_until(func() -> bool:
		api.poll()
		ws.poll()
		return joined[0] and _connected_ids.size() >= before + 2)
	_check(joined[0], "SceneMultiplayer saw the metered ENet client connect")
	_check(_connected_ids.size() == before + 2, "the server saw both join")

	var ws_id := ws.get_unique_id()
	_check(ws_id > 1 and _server.backend_name(ws_id) == "websocket", "the meter reports the inner peer's id")

	# SceneMultiplayer is let go of here: the packets below are raw, and it would read
	# them as commands.
	api.multiplayer_peer = null
	var en_id := en.get_unique_id()
	_server.transfer_channel = DotTransport.Channel.STATE
	for id in [ws_id, en_id]:
		_server.set_target_peer(id)
		_server.put_packet(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
	_server.transfer_channel = 0
	var got := {}
	await _pump_until(func() -> bool:
		for p: DotMeteredPeer in [ws, en]:
			p.poll()
			while p.get_available_packet_count() > 0:
				got[p.transport_name()] = "%d@%d" % [p.get_packet_channel(), p.get_packet().size()]
		return got.size() >= 2)
	_check(got.get("enet", "") == "1@10" and en.bytes_in_by_channel[1] == 10 and en.packets_in >= 1,
		"over ENet a packet arrives whole on its channel, and is counted there (%s)" % [got])
	# [b]WebSocket has no channels.[/b] Godot's WebSocket peer is one ordered stream and
	# reports every packet on channel 0, so a browser cannot split what it receives by
	# channel at all — net_stat says so rather than drawing a breakdown it does not have.
	_check(got.get("websocket", "") == "0@10" and ws.bytes_in == 10 and ws.bytes_in_by_channel[0] == 10,
		"over WebSocket it arrives whole on channel 0, whatever it was sent on (%s)" % [got])

	ws.transfer_channel = 6
	ws.set_target_peer(1)
	var _sent := ws.put_packet(PackedByteArray([0, 0, 0]))
	_check(ws.bytes_out == 3 and ws.bytes_out_by_channel.size() == 7 and ws.bytes_out_by_channel[6] == 3,
		"a send is counted out, on a channel past the four it started with")

	_check(ws.transport_name() == "websocket" and en.transport_name() == "enet", "each names its transport")
	_check(ws.transport_stats().has("queued"), "a WebSocket says what it has not sent yet (%s)" % [ws.transport_stats()])
	_check(en.transport_stats().has("loss") and en.get_peer(1) != null,
		"ENet says its loss, and get_peer still reaches the server (%s)" % [en.transport_stats()])

	en.note_rtt(40.0)
	en.note_rtt(60.0)
	_check(is_equal_approx(en.rtt_jitter_ms, 5.0), "jitter moves a quarter of the way to each difference")

	var left := _disconnected_ids.size()
	en.close()
	ws.close()
	await _pump_until(func() -> bool: return _disconnected_ids.size() >= left + 2, 8.0)


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


## The engine's own lines, caught by a [Logger]: a send to a leaving peer is not an error
## anything returns, only a line on stderr. ENet: "Unable to send packet on channel N, max
## channels: 0" for the one still leaving, "Parameter "peer" is null" for the one already gone.
## WebSocket: "ready_state != STATE_OPEN" for any peer whose socket is no longer open.
class SendWatch:
	extends Logger

	var _mutex := Mutex.new()
	var _count := 0

	func _log_error(
		_function: String, _file: String, _line: int, code: String, rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace],
	) -> void:
		var text := code + " " + rationale
		if (
			text.contains("Unable to send packet")
			or text.contains("Parameter \"peer\" is null")
			or text.contains("ready_state != STATE_OPEN")
		):
			_mutex.lock()
			_count += 1
			_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func count() -> int:
		_mutex.lock()
		var n := _count
		_mutex.unlock()
		return n


## Armed by deleting the [method DotDualPeer._enet_sendable] checks in _put_packet_script:
## the watch then counts the engine's errors, which is what every voice_<game>.log in
## dot-server-deploy carried at a client's disconnect. Deleting only the _enet_departing
## line in _send_enet_except arms it too (the all-but-the-second-leaver send).
func _test_leaving_together() -> void:
	_section("Two ENet clients leaving in one poll: the first one's handler sends to the second")

	var port := PORT + 50
	var t := DotTransportDual.new()
	var made := t.create_server(port, "127.0.0.1")
	if not made.ok or (made.value as DotDualPeer).demux == null:
		_check(false, "a dual server with its UDP port shared")
		return
	var server := made.value as DotDualPeer
	var a := DotTransportENet.new().create_client("127.0.0.1", port).value as MultiplayerPeer
	var b := DotTransportENet.new().create_client("127.0.0.1", port).value as MultiplayerPeer
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and int(server.peer_counts().get("enet", 0)) < 2:
		server.poll()
		a.poll()
		b.poll()
		await get_tree().process_frame
	_check(int(server.peer_counts().get("enet", 0)) == 2, "two ENet clients join")

	# What a game does when a player leaves: tell everybody else, one by one, all-but-one
	# and all at once. Every other peer it still knows of is the second leaver.
	# Read now: a closed ENet client has no id to give.
	var ids: Array[int] = [a.get_unique_id(), b.get_unique_id()]
	var left: Array[int] = []
	var results: Array[int] = []
	var on_left := func(id: int) -> void:
		left.append(id)
		for other: int in ids:
			if other == id or left.has(other):
				continue
			for channel in [0, 2]:
				server.transfer_channel = channel
				server.set_target_peer(other)
				results.append(server.put_packet("left".to_utf8_buffer()))
			server.set_target_peer(-id)
			results.append(server.put_packet("left".to_utf8_buffer()))
			server.set_target_peer(-other)
			results.append(server.put_packet("left".to_utf8_buffer()))
			server.set_target_peer(0)
			results.append(server.put_packet("left".to_utf8_buffer()))
		server.transfer_channel = 0
	server.peer_disconnected.connect(on_left)

	var watch := SendWatch.new()
	OS.add_logger(watch)
	# Both goodbyes on the wire before the server reads either.
	a.close()
	b.close()
	OS.delay_msec(50)
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and left.size() < 2:
		server.poll()
		await get_tree().process_frame
	OS.remove_logger(watch)

	_check(left.size() == 2, "the server saw both leave")
	_check(results.size() >= 5, "the first leaver's handler sent to the second (%d sends)" % results.size())
	_check(watch.count() == 0, "and the engine logged no send to a leaving peer (%d)" % watch.count())
	_check(results.all(func(r: int) -> bool: return r == OK), "every one of those sends reports OK, as ENet's own drop does")
	_check(server.peer_counts() == {"websocket": 0, "enet": 0}, "both are gone from the merged table")
	# The handler holds the server; leave it connected and the two keep each other alive.
	server.peer_disconnected.disconnect(on_left)
	server.close()


## Armed by making [method DotDualPeer._websocket_sendable] return true (the two leavers and
## the server-closed peer fail), or by starting _send_websocket's [code]leaving[/code] at false
## (the lone leaver fails): the watch then counts the engine's "ready_state != STATE_OPEN",
## which every burst run and dot-server-deploy's lookatme_client logged as WebSocket clients left. Three ways a closed socket stays in the
## engine's table: the leaver itself while its peer_disconnected runs (the engine emits before
## it erases, so a plain "player left" broadcast hit it), a second client found closed in the
## same poll, and a peer the server closed, until the next poll.
func _test_websocket_leaving() -> void:
	_section("WebSocket clients leaving: nothing is sent to a socket that is no longer open")

	var port := PORT + 60
	var made := DotTransportDual.new().create_server(port, "127.0.0.1")
	if not made.ok:
		_check(false, "a dual server")
		return
	var server := made.value as DotDualPeer
	var clients: Array[MultiplayerPeer] = []
	for i in 4:
		clients.append(DotTransportWebSocket.new().create_client("ws://127.0.0.1:%d" % port).value)
	var pump := func() -> void:
		server.poll()
		for c in clients:
			c.poll()
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and int(server.peer_counts().get("websocket", 0)) < 4:
		pump.call()
		await get_tree().process_frame
	_check(int(server.peer_counts().get("websocket", 0)) == 4, "four WebSocket clients join")
	var ids: Array[int] = []
	for c in clients:
		ids.append(c.get_unique_id())
	var stayer := clients[3]

	# What a game does when a player leaves: tell everybody, one by one, all-but-one and all.
	var left: Array[int] = []
	var results: Array[int] = []
	var on_left := func(id: int) -> void:
		left.append(id)
		server.set_target_peer(0)
		results.append(server.put_packet("left".to_utf8_buffer()))
		server.set_target_peer(-id)
		results.append(server.put_packet("left".to_utf8_buffer()))
		for other: int in ids:
			if other != id and not left.has(other):
				server.set_target_peer(other)
				results.append(server.put_packet("left".to_utf8_buffer()))
	server.peer_disconnected.connect(on_left)

	var watch := SendWatch.new()
	OS.add_logger(watch)

	# One leaves alone: only the leaver is closed, and the plain broadcast reached it.
	clients[0].close()
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and left.size() < 1:
		pump.call()
		await get_tree().process_frame
	_check(left.size() == 1, "the server saw the first one leave")
	_check(watch.count() == 0, "and logged no send to its closed socket (%d)" % watch.count())

	# Two leave in one poll: the first one's handler sends to the second.
	clients[1].close()
	clients[2].close()
	OS.delay_msec(50)
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and left.size() < 3:
		server.poll()
		stayer.poll()
		await get_tree().process_frame
	_check(left.size() == 3, "the server saw the next two leave")
	_check(watch.count() == 0, "and logged no send to either closed socket (%d)" % watch.count())
	_check(results.all(func(r: int) -> bool: return r == OK), "every send reports OK (%d sends)" % results.size())

	# The one still there heard everything: two broadcasts and one targeted send per leaver.
	# The per-peer path still delivers.
	var heard: Array[String] = []
	deadline = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline and heard.size() < 9:
		server.poll()
		stayer.poll()
		_collect(stayer, heard)
		await get_tree().process_frame
	_check(heard.size() == 9, "the client that stayed heard every broadcast and every send to it (%d)" % heard.size())
	server.peer_disconnected.disconnect(on_left)

	# The server closes one: it stays in the engine's table, closing, until the next poll.
	var stayer_id := ids[3]
	var before := watch.count()
	server.disconnect_peer(stayer_id, false)
	server.set_target_peer(stayer_id)
	var targeted := server.put_packet("bye".to_utf8_buffer())
	server.set_target_peer(0)
	var broadcast := server.put_packet("bye".to_utf8_buffer())
	_check(targeted == OK and broadcast == OK, "sends to a peer the server is closing report OK")
	_check(watch.count() == before, "and the engine logged none of them (%d)" % (watch.count() - before))
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and int(server.peer_counts().get("websocket", 0)) > 0:
		server.poll()
		stayer.poll()
		await get_tree().process_frame
	OS.remove_logger(watch)
	_check(server.peer_counts() == {"websocket": 0, "enet": 0}, "all four are gone from the merged table")
	_check(watch.count() == 0, "no engine send error from the whole section (%d)" % watch.count())
	server.close()


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


## Armed by passing `channel_count` to `create_server` again: the throttle limit falls to
## 1 within a second of traffic and two thirds of the client's packets are dropped.
func _test_enet_server_bandwidth() -> void:
	_section("A server's ENet does not tell its clients to throttle")

	var t := DotTransportENet.new()
	var res := t.create_server(PORT + 20, "127.0.0.1")
	if not res.ok:
		_check(false, "an ENet server listens on %d" % (PORT + 20))
		_check(false, "and keeps its client's packets")
		return
	var server := res.value as ENetMultiplayerPeer
	# Through the transport too, so both ends agree about compression.
	var made := DotTransportENet.new().create_client("127.0.0.1", PORT + 20)
	var client := made.value as ENetMultiplayerPeer if made.ok else ENetMultiplayerPeer.new()
	var sent := 0
	var got := 0
	var lowest := 32
	# Two seconds of a command-sized unreliable packet every frame: ENet's bandwidth
	# throttle runs once a second, so one pass is not enough to see it.
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		server.poll()
		client.poll()
		if client.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			client.set_target_peer(1)
			client.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
			client.put_packet(PackedByteArray([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]))
			sent += 1
			var to_server := client.get_peer(1)
			if to_server != null:
				lowest = mini(lowest, int(to_server.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_LIMIT)))
		while server.get_available_packet_count() > 0:
			server.get_packet()
			got += 1
		OS.delay_msec(8)
	_check(sent > 100 and lowest == 32, "the client's throttle limit stays at full (lowest %d over %d packets)" % [lowest, sent])
	_check(sent > 100 and got >= sent * 9 / 10, "and the server receives its packets (%d of %d)" % [got, sent])
	# The packet throttle (DotTransportENet.packet_throttle_deceleration): set on both ends as
	# they connect, so a late acknowledgement never makes either drop its own unreliable
	# packets. What it costs without is measured in dot-net's relay_demo, section 4.
	var client_side := client.get_peer(1)
	var server_side: ENetPacketPeer = null
	for p in server.host.get_peers():
		server_side = p
	var decel_client := int(client_side.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_DECELERATION)) if client_side != null else -1
	var decel_server := int(server_side.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_DECELERATION)) if server_side != null else -1
	_check(decel_client == 0 and decel_server == 0,
		"neither end's packet throttle falls on a late acknowledgement (deceleration %d and %d)" % [decel_client, decel_server])
	_check(DotTransportENet.new().describe().has("packet_throttle"), "describe() says what the throttle is")
	client.close()
	server.close()


func _test_enet_peer_timeout() -> void:
	_section("A peer that goes quiet for eight seconds is kept, not dropped at ENet's five")

	# ENet's own numbers first, as the control: the same eight seconds must cost the client,
	# or this section could not tell the two apart.
	var stock := DotTransportENet.new()
	stock.peer_timeout_limit = 32
	stock.peer_timeout_min_ms = 5000
	stock.peer_timeout_max_ms = 30000
	var dropped := await _quiet_client(stock, PORT + 21)
	_check(dropped[0], "with ENet's defaults (32, 5 s) the server drops it (%s)" % dropped[1])

	var kept := await _quiet_client(DotTransportENet.new(), PORT + 22)
	_check(not kept[0], "with the transport's defaults the server keeps it (%s)" % kept[1])
	_check(int(kept[2]) > 0 and int(kept[2]) == int(kept[3]),
		"and the client gets every reliable packet once it is back (%d of %d)" % [kept[2], kept[3]])
	_check(DotTransportENet.new().describe().has("peer_timeout"), "describe() says what the timeouts are")


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


## A server closing behind the demux must tell its ENet clients. Closing the ENet host
## sends each peer a disconnect, but to its loopback relay; the dual peer closed the demux
## in the same call, so nothing left, and a native client noticed only at its own peer
## timeout -- 33.8 s in dot-server-deploy's reconnect suite once that was raised to 30 s.
func _test_shutdown_reaches_enet() -> void:
	_section("A server that shuts down tells its ENet clients at once")

	var port := PORT + 40
	var t := DotTransportDual.new()
	var made := t.create_server(port, "127.0.0.1")
	var shared := made.ok and (made.value as DotDualPeer).demux != null
	_check(shared, "a dual server with its UDP port shared")
	if not shared:
		return
	var server := made.value as DotDualPeer
	var client := DotTransportENet.new().create_client("127.0.0.1", port).value as MultiplayerPeer
	var joined := false
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and not joined:
		server.poll()
		client.poll()
		# Both ends: the client says CONNECTED a poll before the server has the peer, and
		# a server that does not know a peer yet has nobody to say goodbye to.
		joined = client.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
			and int(server.peer_counts().get("enet", 0)) == 1
		await get_tree().process_frame
	_check(joined, "the ENet client joins through the demux")

	server.close()
	var started := Time.get_ticks_msec()
	var gone := false
	while Time.get_ticks_msec() - started < 3000 and not gone:
		client.poll()
		gone = client.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED
		await get_tree().process_frame
	var took := Time.get_ticks_msec() - started
	_check(gone and took < 1000, "and learns the server closed in %d ms, not at its peer timeout" % took)
	client.close()


## A native client dials a public server as wss:// first. At a plain listener the engine's
## WebSocket server read the ClientHello waiting for an HTTP header's CRLFCRLF and the client
## waited out its TLS timeout (2.5 s; the server's handshake timeout is 5 s). The screen
## closes anything whose first byte is not 'G'. Armed in-section: the same raw hello at a
## server with [member DotTransportDual.tls_hello_screen] off is still open after a second.
## Auto leaves a loopback listener (a TLS terminator's backend) unscreened.
func _test_tls_hello_screened() -> void:
	_section("A TLS ClientHello at the plain WebSocket port is closed in a round trip")

	var port := PORT + 50
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
	var id := ids[0]

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


## A scanner's plain "GET /" (no Upgrade header) at the WebSocket port. Unscreened it reaches
## the engine, which logs "Missing or invalid header 'upgrade'" (wsl_peer.cpp) as an ERROR
## nothing on our side can lower; screened it is answered and closed here and the engine
## never sees it. Armed: the same bytes at a screen-off server do raise the engine error.
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
