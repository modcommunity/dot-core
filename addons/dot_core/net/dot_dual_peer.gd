class_name DotDualPeer
extends MultiplayerPeerExtension

## A server peer that is two: WebSocket for browsers and ENet for native clients,
## presented to [SceneMultiplayer] as one.
##
## [b]Why one peer and not two MultiplayerAPIs.[/b] Two APIs would be two worlds:
## every RPC, every spawner, every dot-net channel would have to be sent twice and
## a WebSocket player could not see an ENet one. A [MultiplayerPeerExtension] that
## polls both backends and merges their peers into one id space is invisible to
## everything above it — dot-net, dot-server and the games keep one peer.
##
## [b]Peer ids.[/b] ENet clients choose their own id; WebSocket clients are given
## one by the server. Both are random 31-bit numbers drawn independently, so they
## can collide. A peer whose id is already taken by the other backend is
## disconnected rather than renumbered: a renumbered client would believe its own
## id is one the server never uses, and every "this entity is yours" message keyed
## by peer id would silently miss. The chance is about one in thirty million per
## connect at a full server, and the client's reconnect draws a fresh id.
##
## [b]ENet behind a demux.[/b] When [member demux] is set the ENet host sits on
## loopback and sees every client as 127.0.0.1; [method get_peer_address] maps the
## relay back to the real address, which is what bans and rate limits must see.
##
## No ENet identifier is named in this file: the web template has none, and a
## script mentioning one does not compile there. ENet is reached by [method Object.call].

const CHANNEL := "transport"

enum Backend { NONE = 0, WEBSOCKET = 1, ENET = 2 }

## The WebSocket server peer, or null when it could not be created.
var websocket: MultiplayerPeer = null
## The ENet server peer, or null when ENet is unavailable here.
var enet: MultiplayerPeer = null
## The UDP demultiplexer in front of [member enet], or null when ENet binds its
## port directly.
var demux: DotUdpDemux = null

## external peer id -> Backend
var _backend_of: Dictionary = {}
## ENet peer id -> relay loopback port, so the relay closes with its peer.
var _relay_port_of: Dictionary = {}

## Incoming packets drained from both backends: {data, peer, channel, mode}.
var _queue: Array[Dictionary] = []
var _current: Dictionary = {}

var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refusing: bool = false
var _closed: bool = false

var _collisions: int = 0


func setup(p_websocket: MultiplayerPeer, p_enet: MultiplayerPeer, p_demux: DotUdpDemux) -> void:
	websocket = p_websocket
	enet = p_enet
	demux = p_demux

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
			return str(websocket.call("get_peer_address", peer_id))
		Backend.ENET:
			var remote := _enet_remote(peer_id)
			return str(remote.get("ip", ""))
	return ""


## The remote port of a peer, whichever backend it is on.
func get_peer_port(peer_id: int) -> int:
	match backend_of(peer_id):
		Backend.WEBSOCKET:
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
	return lines


# --- Peers -----------------------------------------------------------------

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

	peer_disconnected.emit(id)


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


# --- MultiplayerPeerExtension ------------------------------------------------

func _poll() -> void:
	if _closed:
		return

	if demux != null:
		demux.pump_in()

	if websocket != null:
		websocket.poll()
		_drain(websocket, Backend.WEBSOCKET)

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
		return _send(_inner(backend), target, buffer)

	# 0 is everybody; -id is everybody but id. Each backend gets the broadcast, and
	# only the one holding the excluded peer is told to skip it.
	var excluded_backend := backend_of(-target) if target < 0 else Backend.NONE
	var result := OK
	for backend in [Backend.WEBSOCKET, Backend.ENET]:
		var inner := _inner(backend)
		if inner == null:
			continue
		var err := _send(inner, target if backend == excluded_backend else 0, buffer)
		if err != OK:
			result = err
	return result


func _send(inner: MultiplayerPeer, target: int, buffer: PackedByteArray) -> Error:
	inner.transfer_channel = _transfer_channel
	inner.transfer_mode = _transfer_mode
	inner.set_target_peer(target)
	return inner.put_packet(buffer)


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


func _close() -> void:
	if _closed:
		return
	_closed = true
	for inner in [websocket, enet]:
		if inner != null:
			inner.close()
	if demux != null:
		demux.close()
	_backend_of.clear()
	_relay_port_of.clear()
	_queue.clear()
