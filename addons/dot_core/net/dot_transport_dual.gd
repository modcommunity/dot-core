@tool
class_name DotTransportDual
extends DotTransport

## One server, two audiences: browsers over WebSocket (TCP [code]port[/code]) and native
## clients over ENet (UDP [member enet_port], 0 = same number) in the same match, as a [DotDualPeer].
## With [member share_udp_port] the public UDP port belongs to a [DotUdpDemux] shared with query
## protocols. Never fails to start for ENet: it degrades to WebSocket only with a WARN. Clients use [DotTransportAuto].

## UDP port for ENet. 0: the same number as the game port.
@export var enet_port: int = 0

## Interface ENet's UDP port binds; empty is the server's bind address. Separate because a
## proxied server binds WebSocket to loopback while ENet, which a proxy cannot carry, faces the world.
@export var enet_bind_address: String = ""

## Put ENet and the query protocols on one UDP port via a [DotUdpDemux]. Costs a relay per
## ENet packet, so turn it off when the query protocols use another port.
@export var share_udp_port: bool = true

enum TlsHelloScreen { AUTO = 0, ON = 1, OFF = 2 }

## Whether a [DotTcpScreen] holds the public TCP port with the WebSocket server behind it on
## loopback, closing a TLS ClientHello at once; otherwise a native client waits out its 2.5 s TLS
## timeout before trying ws://. Auto screens every plain listener (about 0.5 ms at 32 clients),
## also behind a proxy, whose scanner traffic the screen stops. Never when the server terminates TLS.
@export_enum("Auto", "On", "Off") var tls_hello_screen: int = TlsHelloScreen.AUTO

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
	var tcp_screen: DotTcpScreen = null
	var ws_res: DotResult = null
	if _screens(ws_t, bind_address):
		var screened := _build_screened_websocket(ws_t, port, bind_address)
		if not screened.ok:
			return screened
		ws_res = DotResult.success(screened.value["peer"])
		tcp_screen = screened.value["screen"]
	else:
		ws_res = ws_t._create_server(port, bind_address)
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
	_peer.setup(ws_peer, enet_peer, mux, tcp_screen)

	DotLog.info(
		CHANNEL,
		"dual transport",
		{
			"websocket_tcp": port,
			"enet_udp": _enet_bound_port if enet_peer != null else 0,
			"shared_udp": mux != null,
			"tls_hello_screen": tcp_screen != null,
		}
	)
	return DotResult.success(_peer as MultiplayerPeer)


func _screens(ws_t: DotTransportWebSocket, _bind_address: String) -> bool:
	if ws_t.use_tls or tls_hello_screen == TlsHelloScreen.OFF:
		return false
	return true


## Whether [param bind_address] listens on loopback only. Empty and "*" are every interface.
static func is_loopback_bind(bind_address: String) -> bool:
	var a := bind_address.strip_edges().to_lower().trim_prefix("[").trim_suffix("]")
	return a == "localhost" or a == "::1" or a.begins_with("127.")


## The public TCP port to a [DotTcpScreen], the WebSocket server on loopback behind it:
## {peer, screen}. The public bind failing fails the server, as it did unscreened; the
## loopback side failing falls back to WebSocket on the public port with a WARN.
func _build_screened_websocket(ws_t: DotTransportWebSocket, port: int, bind_address: String) -> DotResult:
	var tcp_screen := DotTcpScreen.new()
	tcp_screen.first_byte_timeout_sec = ws_t.handshake_timeout_sec
	tcp_screen.max_links = maxi(64, max_clients * 2)
	var opened := tcp_screen.open(port, bind_address, 0)
	if not opened.ok:
		return opened

	# WebSocketMultiplayerPeer cannot say which port 0 gave it, so ask the OS for a free
	# loopback port first. Another process could take it in between; a retry covers that.
	for attempt in 3:
		var inner_port := _free_loopback_port()
		if inner_port <= 0:
			continue
		var made := ws_t._create_server(inner_port, "127.0.0.1")
		if made.ok:
			tcp_screen.set_inner_port(inner_port)
			return DotResult.success({"peer": made.value, "screen": tcp_screen})

	tcp_screen.close()
	DotLog.warn(
		CHANNEL,
		"no loopback port for the WebSocket server; serving it unscreened, a TLS hello waits out the handshake",
		{"setting": "tls_hello_screen"}
	)
	var direct := ws_t._create_server(port, bind_address)
	if not direct.ok:
		return direct
	return DotResult.success({"peer": direct.value, "screen": null})


static func _free_loopback_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var free := probe.get_local_port()
	probe.stop()
	return free


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
