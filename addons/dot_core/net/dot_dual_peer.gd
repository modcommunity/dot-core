class_name DotDualPeer
extends MultiplayerPeerExtension

## A server peer that is two, WebSocket for browsers and ENet for native clients, presented
## to [SceneMultiplayer] as one so every RPC and spawner reaches both.
## Ids collide across backends (random 31-bit); the later peer is disconnected, not renumbered,
## because a renumbered client would never see "this entity is yours". With [member demux] or
## [member screen] set the backends sit on loopback and [method get_peer_address] maps back.
## No ENet identifier is named here (the web template has none); reached by [method Object.call].

const CHANNEL := "transport"

enum Backend { NONE = 0, WEBSOCKET = 1, ENET = 2 }

## The WebSocket server peer, or null when it could not be created.
var websocket: MultiplayerPeer = null
## The ENet server peer, or null when ENet is unavailable here.
var enet: MultiplayerPeer = null
## The UDP demultiplexer in front of [member enet], or null when ENet binds its
## port directly.
var demux: DotUdpDemux = null
## The TCP screen in front of [member websocket], or null when WebSocket binds its port
## directly.
var screen: DotTcpScreen = null

## external peer id -> Backend
var _backend_of: Dictionary = {}
## ENet peer id -> relay loopback port, so the relay closes with its peer.
var _relay_port_of: Dictionary = {}
## WebSocket peer id -> {ip, port} of the client behind the screen, read when it joins: the
## screen's link may close before the peer's peer_disconnected handlers ask.
var _ws_remote_of: Dictionary = {}

## Incoming packets drained from both backends: {data, peer, channel, mode}.
var _queue: Array[Dictionary] = []
var _current: Dictionary = {}

var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refusing: bool = false
var _closed: bool = false
## A [method DotTcpScreen.flush] is queued for the end of this frame.
var _screen_flush_queued: bool = false

var _collisions: int = 0
## The ENet peer whose peer_disconnected is being emitted right now, or 0.
var _enet_departing: int = 0
## The WebSocket peer whose peer_disconnected is being emitted right now, or 0.
var _websocket_departing: int = 0


func setup(
	p_websocket: MultiplayerPeer, p_enet: MultiplayerPeer, p_demux: DotUdpDemux, p_screen: DotTcpScreen = null
) -> void:
	websocket = p_websocket
	enet = p_enet
	demux = p_demux
	screen = p_screen

	if websocket != null:
		websocket.peer_connected.connect(_on_connected.bind(Backend.WEBSOCKET))
		websocket.peer_disconnected.connect(_on_disconnected.bind(Backend.WEBSOCKET))
	if enet != null:
		enet.peer_connected.connect(_on_connected.bind(Backend.ENET))
		enet.peer_disconnected.connect(_on_disconnected.bind(Backend.ENET))


## Which backend a peer arrived on. [constant Backend.NONE] for an unknown id.
func backend_of(peer_id: int) -> int:
	return int(_backend_of.get(peer_id, Backend.NONE))


## "websocket", "enet" or "".
func backend_name(peer_id: int) -> String:
	match backend_of(peer_id):
		Backend.WEBSOCKET:
			return "websocket"
		Backend.ENET:
			return "enet"
	return ""


## The remote address of a peer, whichever backend it is on.
func get_peer_address(peer_id: int) -> String:
	match backend_of(peer_id):
		Backend.WEBSOCKET:
			if _ws_remote_of.has(peer_id):
				return str(_ws_remote_of[peer_id]["ip"])
			return str(websocket.call("get_peer_address", peer_id))
		Backend.ENET:
			var remote := _enet_remote(peer_id)
			return str(remote.get("ip", ""))
	return ""


## The remote port of a peer, whichever backend it is on.
func get_peer_port(peer_id: int) -> int:
	match backend_of(peer_id):
		Backend.WEBSOCKET:
			if _ws_remote_of.has(peer_id):
				return int(_ws_remote_of[peer_id]["port"])
			return int(websocket.call("get_peer_port", peer_id))
		Backend.ENET:
			return int(_enet_remote(peer_id).get("port", 0))
	return 0


func peer_counts() -> Dictionary:
	var ws := 0
	var en := 0
	for id in _backend_of:
		if _backend_of[id] == Backend.WEBSOCKET:
			ws += 1
		else:
			en += 1
	return {"websocket": ws, "enet": en}


func describe() -> Dictionary:
	var d := {
		"websocket": websocket != null,
		"enet": enet != null,
		"peers": peer_counts(),
		"id_collisions": _collisions,
	}
	if demux != null:
		d["demux"] = demux.describe()
	if screen != null:
		d["screen"] = screen.describe()
	return d


func describe_lines() -> PackedStringArray:
	var counts := peer_counts()
	var lines := PackedStringArray()
	lines.append("websocket: %s, %d peer(s)" % ["on" if websocket != null else "off", counts["websocket"]])
	lines.append("enet: %s, %d peer(s)" % ["on" if enet != null else "off", counts["enet"]])
	if demux != null:
		var dm := demux.describe()
		lines.append(
			"udp %d shared: %d relay(s), %d in / %d out relayed, %d handled, %d dropped"
			% [dm["port"], dm["relays"], dm["relayed_in"], dm["relayed_out"], dm["handled"], dm["dropped"]]
		)
	if screen != null:
		var sc := screen.describe()
		lines.append(
			"tcp %d screened: %d link(s), %d relayed, %d refused (%d TLS, %d HTTP), %d timed out, %d over limit"
			% [sc["port"], sc["links"], sc["relayed"], sc["refused"], sc["refused_tls"], sc["refused_http"], sc["timed_out"], sc["over_limit"]]
		)
	return lines



func _on_connected(id: int, backend: int) -> void:
	if _backend_of.has(id):
		_collisions += 1
		DotLog.warn(
			CHANNEL,
			"peer id taken by the other backend; disconnecting the newcomer",
			{"id": id, "backend": backend}
		)
		_inner(backend).disconnect_peer(id, true)
		return

	_backend_of[id] = backend
	if backend == Backend.ENET and demux != null:
		_relay_port_of[id] = _enet_raw_port(id)
	if backend == Backend.WEBSOCKET and screen != null:
		var remote := screen.remote_for_inner_port(int(websocket.call("get_peer_port", id)))
		if not remote.is_empty():
			_ws_remote_of[id] = remote

	DotLog.debug(
		CHANNEL, "peer joined", {"id": id, "backend": "enet" if backend == Backend.ENET else "websocket"}
	)
	peer_connected.emit(id)


func _on_disconnected(id: int, backend: int) -> void:
	# A collision's newcomer was never admitted; its disconnect is not ours to report.
	if int(_backend_of.get(id, Backend.NONE)) != backend:
		return

	_backend_of.erase(id)
	if _relay_port_of.has(id):
		if demux != null:
			demux.release_relay_port(int(_relay_port_of[id]))
		_relay_port_of.erase(id)

	# Both backends emit this before they drop the peer from their own table; see
	# _send_enet_except and _send_websocket.
	var outer_enet := _enet_departing
	var outer_websocket := _websocket_departing
	if backend == Backend.ENET:
		_enet_departing = id
	else:
		_websocket_departing = id
	peer_disconnected.emit(id)
	_ws_remote_of.erase(id)
	_enet_departing = outer_enet
	_websocket_departing = outer_websocket


func _inner(backend: int) -> MultiplayerPeer:
	return enet if backend == Backend.ENET else websocket


func _enet_raw_port(peer_id: int) -> int:
	var packet_peer: Object = enet.call("get_peer", peer_id)
	if packet_peer == null:
		return 0
	return int(packet_peer.call("get_remote_port"))


func _enet_remote(peer_id: int) -> Dictionary:
	var packet_peer: Object = enet.call("get_peer", peer_id)
	if packet_peer == null:
		return {}
	var ip := str(packet_peer.call("get_remote_address"))
	var port := int(packet_peer.call("get_remote_port"))
	if demux == null:
		return {"ip": ip, "port": port}
	var relay_port := int(_relay_port_of.get(peer_id, port))
	var remote := demux.remote_for_relay_port(relay_port)
	return remote if not remote.is_empty() else {"ip": ip, "port": port}



func _poll() -> void:
	if _closed:
		return

	if demux != null:
		demux.pump_in()

	# Client bytes cross the screen before the WebSocket server reads, and its replies
	# cross back right after it writes (it writes in poll), so the screen adds no frame.
	if screen != null:
		screen.pump_in()

	if websocket != null:
		websocket.poll()
		_drain(websocket, Backend.WEBSOCKET)

	if screen != null:
		screen.pump_out()

	if enet != null:
		enet.poll()
		_drain(enet, Backend.ENET)

	if demux != null:
		demux.pump_out()


## Moves a backend's packets into the merged queue. Peer, channel and mode are
## read before [code]get_packet[/code]: both backends describe the packet at the
## FRONT of their queue, and popping it first would describe the next one.
func _drain(peer: MultiplayerPeer, backend: int) -> void:
	while peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var channel := peer.get_packet_channel()
		var mode := peer.get_packet_mode()
		var data := peer.get_packet()
		if int(_backend_of.get(from, Backend.NONE)) != backend:
			continue
		_queue.append({"data": data, "peer": from, "channel": channel, "mode": mode})


func _get_available_packet_count() -> int:
	return _queue.size()


func _get_packet_script() -> PackedByteArray:
	if _queue.is_empty():
		return PackedByteArray()
	_current = _queue.pop_front()
	return _current["data"]


func _get_packet_peer() -> int:
	if not _queue.is_empty():
		return int(_queue[0]["peer"])
	return int(_current.get("peer", 0))


func _get_packet_channel() -> int:
	if not _queue.is_empty():
		return int(_queue[0]["channel"])
	return int(_current.get("channel", 0))


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	if not _queue.is_empty():
		return _queue[0]["mode"]
	return _current.get("mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _closed:
		return ERR_UNCONFIGURED

	var target := _target_peer

	if target > 0:
		var backend := backend_of(target)
		if backend == Backend.NONE:
			return ERR_INVALID_PARAMETER
		if not _sendable(backend, target):
			# Leaving: its disconnect event is on its way. ENet drops a send to a peer that is
			# disconnecting without a word, and so does this, on either backend.
			return OK
		return _send(_inner(backend), target, buffer)

	# 0 is everybody; -id is everybody but id. Each backend gets the broadcast, and
	# only the one holding the excluded peer is told to skip it.
	var excluded_backend := backend_of(-target) if target < 0 else Backend.NONE
	var result := OK
	for backend in [Backend.WEBSOCKET, Backend.ENET]:
		var inner := _inner(backend)
		if inner == null:
			continue
		var err := OK
		if backend == Backend.WEBSOCKET:
			err = _send_websocket(-target if backend == excluded_backend else 0, buffer)
		elif backend == excluded_backend:
			err = _send_enet_except(-target, buffer)
		else:
			err = _send(inner, 0, buffer)
		if err != OK:
			result = err
	return result


func _send(inner: MultiplayerPeer, target: int, buffer: PackedByteArray) -> Error:
	inner.transfer_channel = _transfer_channel
	inner.transfer_mode = _transfer_mode
	inner.set_target_peer(target)
	var err := inner.put_packet(buffer)
	if screen != null and inner == websocket and not _screen_flush_queued:
		# Once per frame, not per packet: a flush visits every link.
		_screen_flush_queued = true
		_flush_screen.call_deferred()
	return err


func _flush_screen() -> void:
	_screen_flush_queued = false
	if not _closed and screen != null:
		screen.flush()


func _sendable(backend: int, peer_id: int) -> bool:
	return _enet_sendable(peer_id) if backend == Backend.ENET else _websocket_sendable(peer_id)


## Whether a WebSocket peer is still open. The engine keeps a closed peer in its table until
## the next poll or its peer_disconnected, and each send to it logs "ready_state != STATE_OPEN".
## A peer that is not a WebSocketMultiplayerPeer's (a test's stand-in) is taken as open.
func _websocket_sendable(peer_id: int) -> bool:
	var server := websocket as WebSocketMultiplayerPeer
	if server == null:
		return true
	var link := server.get_peer(peer_id)
	return link != null and link.get_ready_state() == WebSocketPeer.STATE_OPEN


## Everybody on WebSocket, or all but [param excluded] when not 0. The engine broadcast also
## hits a peer already closed mid-departure, so when one is in the table each open peer is
## sent to individually; otherwise it is one engine broadcast.
func _send_websocket(excluded: int, buffer: PackedByteArray) -> Error:
	var live: Array[int] = []
	var leaving := _websocket_departing != 0 and _websocket_departing != excluded
	for id: int in _backend_of:
		if _backend_of[id] != Backend.WEBSOCKET or id == excluded:
			continue
		if _websocket_sendable(id):
			live.append(id)
		else:
			leaving = true
	if not leaving:
		return _send(websocket, -excluded, buffer)
	var result := OK
	for id in live:
		var err := _send(websocket, id, buffer)
		if err != OK:
			result = err
	return result


## Whether ENet can still take a packet for this peer. A departing client's channels are freed
## when its datagram is read but it stays in the table until its DISCONNECT dispatches, so a
## send hit "Unable to send packet on channel N, max channels: 0". Only the peer shows it.
func _enet_sendable(peer_id: int) -> bool:
	var packet_peer: Object = enet.call("get_peer", peer_id)
	return packet_peer != null and int(packet_peer.call("get_channels")) > 0


## Everybody on ENet but [param excluded]. ENet's all-but-one loop sends to a leaving peer
## ([method _enet_sendable]) and to one whose peer is already null; when either is present
## this sends per live peer, otherwise one engine broadcast (one host flush).
func _send_enet_except(excluded: int, buffer: PackedByteArray) -> Error:
	var live: Array[int] = []
	var leaving := _enet_departing != 0 and _enet_departing != excluded
	for id: int in _backend_of:
		if _backend_of[id] != Backend.ENET or id == excluded:
			continue
		if _enet_sendable(id):
			live.append(id)
		else:
			leaving = true
	if not leaving:
		return _send(enet, -excluded, buffer)
	var result := OK
	for id in live:
		var err := _send(enet, id, buffer)
		if err != OK:
			result = err
	return result


func _get_max_packet_size() -> int:
	var size := 1 << 24
	if websocket != null:
		size = mini(size, websocket.get_max_packet_size())
	if enet != null:
		size = mini(size, enet.get_max_packet_size())
	return size


func _set_target_peer(peer: int) -> void:
	_target_peer = peer


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode


func _get_unique_id() -> int:
	return 1


func _is_server() -> bool:
	return true


func _is_server_relay_supported() -> bool:
	return true


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	if _closed:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	for inner in [websocket, enet]:
		if inner != null and inner.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return MultiplayerPeer.CONNECTION_CONNECTED
	return MultiplayerPeer.CONNECTION_DISCONNECTED


func _set_refuse_new_connections(enable: bool) -> void:
	_refusing = enable
	for inner in [websocket, enet]:
		if inner != null:
			inner.refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return _refusing


func _disconnect_peer(peer: int, force: bool) -> void:
	var backend := backend_of(peer)
	if backend == Backend.NONE:
		return
	_inner(backend).disconnect_peer(peer, force)
	if force:
		_on_disconnected(peer, backend)


## Tell every ENet client the server is going, through the demux, before closing. Behind the
## demux a send reaches only the loopback relay until pump_out(), so closing at once sent
## nothing and clients learned of it from their peer timeout. Disconnect gracefully, service
## the host and forward, a few times over a few milliseconds.
func _say_goodbye_through_demux() -> void:
	for id: int in _backend_of.keys():
		if _backend_of[id] == Backend.ENET:
			enet.disconnect_peer(id, false)

	for i in 4:
		enet.poll()
		demux.pump_out()
		OS.delay_usec(2000)


func _close() -> void:
	if _closed:
		return
	_closed = true
	if enet != null and demux != null:
		_say_goodbye_through_demux()
	for inner in [websocket, enet]:
		if inner != null:
			inner.close()
	if demux != null:
		demux.close()
	if screen != null:
		# What the WebSocket server wrote as it closed is still on loopback.
		screen.pump_out()
		screen.close()
	_backend_of.clear()
	_ws_remote_of.clear()
	_relay_port_of.clear()
	_queue.clear()
