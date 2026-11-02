extends Node

## The web transport's message limits: a worst-case snapshot burst, the largest scoreboard and the largest message cross a real WebSocket pair on loopback,
## and the old 64 KiB buffers are shown to refuse an oversize message (the control).
## Run: [code]godot --headless --path . res://examples/web_limits_selftest.tscn[/code]

const SECTIONS := 4
const CHECKS := 19
const PORT := 47393
## dot-net's DotNetPacket.MAX_FRAGMENTS and DEFAULT_MTU less its 8-byte fragment header.
const SNAPSHOT_FRAGMENTS := 255
const FRAGMENT_BYTES := 1192
## dot-server's SCOREBOARD_MAX_BYTES.
const SCOREBOARD_BYTES := 16384

var _passed := 0
var _failed := 0
var _sections := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	print("dot-core web limits self-test")
	var t := DotTransportWebSocket.new()
	await _defaults()
	await _burst("defaults", t, DotTransportWebSocket.new(), true)
	await _burst("a server with the dot-server buffers", _server_side(), DotTransportWebSocket.new(), true)
	await _burst("the old 64 KiB buffers (control)", _small(), _small(), false)
	print("%d sections, %d passed, %d failed" % [_sections, _passed, _failed])
	var bad := _sections != SECTIONS or _passed + _failed != CHECKS or _failed > 0
	if _sections != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections and %d checks ran, %d and %d expected" % [_sections, _passed + _failed, SECTIONS, CHECKS])
	get_tree().quit(1 if bad else 0)


func _server_side() -> DotTransportWebSocket:
	var t := DotTransportWebSocket.new()
	t.inbound_buffer_exp = 17
	return t


func _small() -> DotTransportWebSocket:
	var t := DotTransportWebSocket.new()
	t.inbound_buffer_exp = 16
	t.outbound_buffer_exp = 16
	t.max_queued_packets = 2048
	return t


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("   ok   ", what)
	else:
		_failed += 1
		print("  FAIL  ", what)


func _defaults() -> void:
	_sections += 1
	print("-- the defaults hold the worst case")
	var t := DotTransportWebSocket.new()
	_check(t.max_message_bytes() >= SNAPSHOT_FRAGMENTS * FRAGMENT_BYTES, "a max-fragment snapshot (%d B) fits one buffer (%d B)" % [SNAPSHOT_FRAGMENTS * FRAGMENT_BYTES, t.max_message_bytes()])
	_check(t.max_queued_packets >= SNAPSHOT_FRAGMENTS * 8, "the packet queue holds eight worst-case snapshots")
	_check(t.max_message_bytes() >= SCOREBOARD_BYTES * 8, "and a scoreboard many times over")


## [param expect_ok] false is the control: the burst is expected to lose data.
func _burst(label: String, server_t: DotTransportWebSocket, client_t: DotTransportWebSocket, expect_ok: bool) -> void:
	_sections += 1
	print("-- ", label)
	var s := server_t.create_server(PORT, "127.0.0.1")
	if not s.ok:
		_check(false, "listens: %s" % s.message)
		return
	var server := s.value as MultiplayerPeer
	var ids: Array[int] = []
	server.peer_connected.connect(func(id: int) -> void: ids.append(id))
	var client := client_t.create_client("ws://127.0.0.1:%d" % PORT).value as MultiplayerPeer
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and (ids.is_empty() or client.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED):
		server.poll()
		client.poll()
		await get_tree().process_frame
	_check(ids.size() == 1, "client joins")
	if ids.is_empty():
		server.close()
		client.close()
		return
	var id := ids[0]
	server.set_target_peer(id)
	server.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	var frag := PackedByteArray()
	frag.resize(FRAGMENT_BYTES + 8)
	var sent_ok := 0
	for i in SNAPSHOT_FRAGMENTS:
		frag[0] = i
		if server.put_packet(frag) == OK:
			sent_ok += 1
	var got := await _drain(server, client, SNAPSHOT_FRAGMENTS)
	if expect_ok:
		_check(sent_ok == SNAPSHOT_FRAGMENTS and got == SNAPSHOT_FRAGMENTS, "a %d-fragment snapshot burst arrives whole (%d sent, %d received)" % [SNAPSHOT_FRAGMENTS, sent_ok, got])
		var board := PackedByteArray()
		board.resize(SCOREBOARD_BYTES)
		server.set_target_peer(id)
		_check(server.put_packet(board) == OK, "a %d B scoreboard is accepted" % SCOREBOARD_BYTES)
		_check(await _drain(server, client, 1) == 1, "and arrives as one message")
		var big := PackedByteArray()
		big.resize(server_t.max_message_bytes())
		server.set_target_peer(id)
		_check(server.put_packet(big) == OK, "the largest single message (%d B) is accepted" % big.size())
		_check(await _drain(server, client, 1) == 1, "and arrives")
		client.set_target_peer(1)
		var cmd := PackedByteArray()
		cmd.resize(4096)
		_check(client.put_packet(cmd) == OK and await _drain(client, server, 1) == 1, "a max_client_payload command reaches the server")
	else:
		var over := PackedByteArray()
		over.resize(FRAGMENT_BYTES * 90)
		server.set_target_peer(id)
		server.put_packet(over)
		_check(await _drain(server, client, 1) == 0, "a %d B message never arrives over 64 KiB buffers, so the raise matters" % over.size())
	server.close()
	client.close()
	for i in 10:
		await get_tree().process_frame


## Polls both ends; counts packets the receiver can read, until [param want] or 2 s.
func _drain(sender: MultiplayerPeer, receiver: MultiplayerPeer, want: int) -> int:
	var got := 0
	var end := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < end and got < want:
		sender.poll()
		receiver.poll()
		while receiver.get_available_packet_count() > 0:
			receiver.get_packet()
			got += 1
		await get_tree().process_frame
	return got
