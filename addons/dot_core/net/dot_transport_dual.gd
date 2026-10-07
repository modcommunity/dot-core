@tool
class_name DotTransportDual
extends DotTransport

## One server, two audiences: browsers over WebSocket and native clients over ENet,
## in the same match.
##
## WebSocket listens on TCP [code]port[/code]; ENet on UDP [member enet_port] (0:
## the same number — TCP and UDP ports are separate namespaces, so that costs
## nothing). The server peer is a [DotDualPeer], which [SceneMultiplayer] sees as
## a single peer.
##
## [b]Sharing the UDP port with a query protocol.[/b] A2S and DQP answer on the game
## port by default. ENet cannot share a socket with them (Godot binds no receive
## hook on [code]ENetConnection[/code]), so when [member share_udp_port] is on the
## public UDP port belongs to a [DotUdpDemux]: query datagrams go to the handlers
## a query host registers with [method add_datagram_handler], everything else is
## relayed to an ENet host on loopback. With it off, ENet binds [member enet_port]
## itself and the query protocols need a port of their own.
##
## [b]It never fails to start because of ENet.[/b] No ENet in this build, a busy
## UDP port, a failed loopback bind: each degrades to WebSocket only with a WARN
## that names the setting, because a server browsers can still join is better than
## one that is down.
##
## A client never uses this class. A client connects with one transport; see
## [DotTransportAuto] and dot-server's client link, which try ENet first on a
## native build when the server advertises it.

## UDP port for ENet. 0: the same number as the game port.
@export var enet_port: int = 0

## Interface ENet's UDP port binds. Empty: the server's bind address.
##
## Separate because a reverse-proxied server binds its WebSocket to loopback and lets
## the proxy face the world — and a proxy for WebSocket cannot carry UDP, so ENet has
## to face the world itself.
@export var enet_bind_address: String = ""

## Put ENet and the connectionless query protocols on one UDP port via a
## [DotUdpDemux]. Only has an effect when a handler is registered on the same port,
## but costs a relay per ENet packet either way, so a server whose query protocols
## are on another port should turn it off.
@export var share_udp_port: bool = true

## Sub-transport for browsers. Created with defaults if unset.
@export var websocket: DotTransportWebSocket = null

## Sub-transport for native clients. Created with defaults if unset.
@export var enet: DotTransportENet = null

var _peer: DotDualPeer = null
var _enet_bound_port: int = 0
var _enet_reason: String = ""


func _transport_name() -> String:
	return "Dual"


func supports_web_clients() -> bool:
	return true


## Whether native clients can reach ENet on this server right now (after listen).
func serves_enet() -> bool:
	return _peer != null and _peer.enet != null


## The UDP port native clients connect to, or 0 when ENet is off.
func advertised_enet_port() -> int:
	return _enet_bound_port if serves_enet() else 0


## The demux owning the public UDP port, or null.
func demux() -> DotUdpDemux:
	return _peer.demux if _peer != null else null


## Registers a connectionless protocol on the shared UDP port. Returns false when
## there is no demux (ENet off, or bound directly), and the caller binds its own.
func add_datagram_handler(port: int, claim: Callable, handle: Callable) -> bool:
	var d := demux()
	if d == null or d.public_port() != port:
		return false
	d.add_handler(claim, handle)
	return true


func scheme() -> String:
	return _websocket().scheme()


func _is_available() -> DotResult:
	return _websocket()._is_available()


func _create_server(port: int, bind_address: String) -> DotResult:
	var ws_t := _websocket()
	_share_limits(ws_t)
	var ws_res := ws_t._create_server(port, bind_address)
	if not ws_res.ok:
		return ws_res

	var ws_peer: MultiplayerPeer = ws_res.value
	var udp_port := enet_port if enet_port > 0 else port

	var enet_peer: MultiplayerPeer = null
	var mux: DotUdpDemux = null
	var udp_bind := enet_bind_address if enet_bind_address.strip_edges() != "" else bind_address
	var built := _build_enet(udp_port, udp_bind)
	if built.ok:
		enet_peer = built.value["peer"]
		mux = built.value["demux"]
		_enet_bound_port = udp_port
		# Port 0 asked the OS for one; advertise the one it gave.
		if udp_port == 0:
			if mux != null:
				_enet_bound_port = mux.public_port()
			else:
				var host: Object = enet_peer.call("get_host")
				_enet_bound_port = int(host.call("get_local_port")) if host != null else 0
	else:
		_enet_reason = built.error.message
		DotLog.warn(
			CHANNEL,
			"ENet unavailable, serving WebSocket only — native clients will use WebSocket",
			{"why": built.error.message, "detail": built.error.detail, "setting": "enet_port"}
		)

	_peer = DotDualPeer.new()
	_peer.setup(ws_peer, enet_peer, mux)

	DotLog.info(
		CHANNEL,
		"dual transport",
		{
			"websocket_tcp": port,
			"enet_udp": _enet_bound_port if enet_peer != null else 0,
			"shared_udp": mux != null,
		}
	)
	return DotResult.success(_peer as MultiplayerPeer)


func _build_enet(udp_port: int, bind_address: String) -> DotResult:
	var en := _enet()
	_share_limits(en)
	var avail := en._is_available()
	if not avail.ok:
		return avail

	if not share_udp_port:
		var direct := en._create_server(udp_port, bind_address)
		if not direct.ok:
			return direct
		return DotResult.success({"peer": direct.value, "demux": null})

	# ENet on loopback, on a port the OS picks: nothing outside reaches it except
	# through the demux, and ENet's own bind cannot collide with the public one.
	var internal := en._create_server(0, "127.0.0.1")
	if not internal.ok:
		return internal

	var peer: MultiplayerPeer = internal.value
	var host: Object = peer.call("get_host")
	var loopback_port := int(host.call("get_local_port")) if host != null else 0
	if loopback_port <= 0:
		peer.close()
		return DotResult.fail(DotError.CODE_INTERNAL, "ENet's loopback port is unknown.")

	var mux := DotUdpDemux.new()
	mux.max_relays = maxi(64, max_clients * 2)
	var opened := mux.open(udp_port, bind_address, loopback_port)
	if not opened.ok:
		peer.close()
		return opened

	return DotResult.success({"peer": peer, "demux": mux})


func _create_client(address: String, port: int) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED,
		"DotTransportDual is server-only.",
		"a client connects with DotTransportENet or DotTransportWebSocket"
	)


func _share_limits(t: DotTransport) -> void:
	t.max_clients = max_clients
	t.in_bandwidth = in_bandwidth
	t.out_bandwidth = out_bandwidth
	t.connect_timeout_sec = connect_timeout_sec


func _websocket() -> DotTransportWebSocket:
	if websocket == null:
		websocket = DotTransportWebSocket.new()
	return websocket


func _enet() -> DotTransportENet:
	if enet == null:
		enet = DotTransportENet.new()
	return enet


func describe() -> Dictionary:
	var d := super.describe()
	d["enet_port"] = advertised_enet_port()
	d["enet_off_because"] = _enet_reason
	if _peer != null:
		d["peer"] = _peer.describe()
	return d
