class_name DotUdpDemux
extends RefCounted

## One public UDP port shared by ENet and connectionless protocols (A2S, DQP).
##
## [b]Why this exists.[/b] Godot's [code]ENetConnection[/code] can send raw datagrams
## from its socket ([code]socket_send[/code]) but exposes no receive hook — C ENet's
## [code]host->intercept[/code] is not bound. An A2S query arriving at an ENet host
## is silently dropped, so the game port cannot be handed to ENet and also answer a
## server browser. This class owns the public port instead:
##
## [codeblock]
## datagram in on the public port
##   claimed by a handler (A2S: FF FF FF FF, DQP: "DQP1")  -> handler, replies out
##   otherwise                                            -> ENet, via a relay
## [/codeblock]
##
## The ENet host listens on loopback, on a port the OS picks. Every remote client
## gets its OWN loopback relay socket, so ENet sees one distinct peer per client
## (one shared socket would make every client the same peer). What ENet sends to a
## relay goes back out of the public socket to the remote it stands for.
##
## [b]The relay hides the client's address from ENet[/b], which would see
## 127.0.0.1 for everyone. [method remote_for_relay_port] maps it back; the dual
## peer answers [code]get_peer_address[/code] with the real one, so bans, rate
## limits and logs keep working.
##
## [b]Telling ENet from the rest.[/b] Handlers are asked first. A connectionless
## datagram begins FF FF FF FF; an ENet datagram begins with a 16-bit peer id whose
## top bits are flags, so 0xFFFF followed by a 16-bit sent-time of 0xFFFF can in
## principle occur — only on a compressed connect, one time in 65536. That datagram
## is lost to the handler, and ENet retransmits a connect it gets no answer to, so
## the cost of the collision is one retry. A relay is only created for a datagram
## whose peer-id field is ENet's "not yet connected" id (0xFFF), so random noise and
## spoofed floods cannot open a socket per source address.

const CHANNEL := "transport"

## ENet's peer id before the handshake assigns one (ENET_PROTOCOL_MAXIMUM_PEER_ID).
const ENET_UNASSIGNED_PEER := 0x0FFF

## Seconds a relay may sit unused before it is closed. ENet's own peer timeout is
## 30 s at most, so a relay idle for longer has no live ENet peer behind it.
const RELAY_IDLE_SEC := 45.0

## A handler: [code]claim(data: PackedByteArray) -> bool[/code] and
## [code]handle(data, ip, port) -> Array[PackedByteArray][/code] (replies).
var _handlers: Array[Dictionary] = []

var _public: PacketPeerUDP = null
var _enet_port: int = 0

## Most relays allowed at once. Bounds the sockets a flood can open.
var max_relays: int = 128

## "ip|port" -> {socket, ip, port, relay_port, seen}
var _relays: Dictionary = {}
## relay local port -> "ip|port"
var _by_relay_port: Dictionary = {}

var _relayed_in: int = 0
var _relayed_out: int = 0
var _handled: int = 0
var _dropped: int = 0


## Binds the public port. [param enet_port] is the loopback port the ENet host
## listens on.
func open(port: int, bind_address: String, enet_port: int) -> DotResult:
	_public = PacketPeerUDP.new()
	var bind := bind_address if bind_address != "" else "*"
	var err := _public.bind(port, bind)
	if err != OK:
		_public = null
		return DotResult.failure(
			DotError.from_engine(err, "binding UDP port %d" % port)
		)

	_enet_port = enet_port
	return DotResult.success(port)


func is_open() -> bool:
	return _public != null


func public_port() -> int:
	return _public.get_local_port() if _public != null else 0


## Registers a connectionless protocol on this port. See [member _handlers].
func add_handler(claim: Callable, handle: Callable) -> void:
	_handlers.append({"claim": claim, "handle": handle})


func remove_handler(handle: Callable) -> void:
	for i in range(_handlers.size() - 1, -1, -1):
		if _handlers[i]["handle"] == handle:
			_handlers.remove_at(i)


## Moves datagrams from the public port to handlers and relays. Call before the
## ENet host is serviced.
func pump_in() -> void:
	if _public == null:
		return

	while _public.get_available_packet_count() > 0:
		var data := _public.get_packet()
		var ip := _public.get_packet_ip()
		var port := _public.get_packet_port()

		if _dispatch(data, ip, port):
			continue

		var relay := _relay_for(ip, port, data)
		if relay.is_empty():
			_dropped += 1
			continue

		(relay["socket"] as PacketPeerUDP).put_packet(data)
		relay["seen"] = Time.get_ticks_msec()
		_relayed_in += 1


## Moves what ENet sent to each relay back out to its remote. Call after the ENet
## host is serviced.
func pump_out() -> void:
	if _public == null:
		return

	var now := Time.get_ticks_msec()
	var stale: Array = []

	for key in _relays:
		var relay: Dictionary = _relays[key]
		var socket: PacketPeerUDP = relay["socket"]
		var sent := false
		while socket.get_available_packet_count() > 0:
			var data := socket.get_packet()
			_public.set_dest_address(relay["ip"], relay["port"])
			_public.put_packet(data)
			_relayed_out += 1
			sent = true
		if sent:
			relay["seen"] = now
		elif now - int(relay["seen"]) > int(RELAY_IDLE_SEC * 1000.0):
			stale.append(key)

	for key in stale:
		_close_relay(key)


## The real remote behind a relay's loopback port, or an empty dictionary.
func remote_for_relay_port(relay_port: int) -> Dictionary:
	var key: Variant = _by_relay_port.get(relay_port)
	if key == null:
		return {}
	var relay: Dictionary = _relays.get(key, {})
	if relay.is_empty():
		return {}
	return {"ip": relay["ip"], "port": relay["port"]}


## Closes the relay standing for a loopback port (its ENet peer has gone).
func release_relay_port(relay_port: int) -> void:
	var key: Variant = _by_relay_port.get(relay_port)
	if key != null:
		_close_relay(key)


func relay_count() -> int:
	return _relays.size()


func close() -> void:
	for key in _relays.keys():
		_close_relay(key)
	if _public != null:
		_public.close()
		_public = null


func describe() -> Dictionary:
	return {
		"port": public_port(),
		"enet_loopback_port": _enet_port,
		"relays": _relays.size(),
		"handlers": _handlers.size(),
		"relayed_in": _relayed_in,
		"relayed_out": _relayed_out,
		"handled": _handled,
		"dropped": _dropped,
	}


func _dispatch(data: PackedByteArray, ip: String, port: int) -> bool:
	for h in _handlers:
		if not bool((h["claim"] as Callable).call(data)):
			continue
		_handled += 1
		var replies: Variant = (h["handle"] as Callable).call(data, ip, port)
		if replies is Array:
			for reply in replies:
				_public.set_dest_address(ip, port)
				_public.put_packet(reply)
		return true
	return false


## True when a datagram is an ENet connect: its peer-id field is the unassigned id.
static func is_enet_connect(data: PackedByteArray) -> bool:
	if data.size() < 4:
		return false
	var header := (data[0] << 8) | data[1]
	return (header & 0x0FFF) == ENET_UNASSIGNED_PEER


func _relay_for(ip: String, port: int, data: PackedByteArray) -> Dictionary:
	var key := "%s|%d" % [ip, port]
	var relay: Dictionary = _relays.get(key, {})
	if not relay.is_empty():
		return relay

	# Only a connect opens a relay. Anything else from an unknown source is noise,
	# or a packet for a peer whose relay has already expired.
	if not is_enet_connect(data):
		return {}

	if _relays.size() >= max_relays:
		DotLog.warn(CHANNEL, "udp relay limit reached", {"limit": max_relays, "from": ip})
		return {}

	var socket := PacketPeerUDP.new()
	if socket.bind(0, "127.0.0.1") != OK:
		DotLog.warn(CHANNEL, "could not open a udp relay socket", {"from": ip})
		return {}
	socket.set_dest_address("127.0.0.1", _enet_port)

	relay = {
		"socket": socket,
		"ip": ip,
		"port": port,
		"relay_port": socket.get_local_port(),
		"seen": Time.get_ticks_msec(),
	}
	_relays[key] = relay
	_by_relay_port[relay["relay_port"]] = key
	DotLog.debug(CHANNEL, "udp relay opened", {"from": ip, "port": port})
	return relay


func _close_relay(key: Variant) -> void:
	var relay: Dictionary = _relays.get(key, {})
	if relay.is_empty():
		return
	(relay["socket"] as PacketPeerUDP).close()
	_by_relay_port.erase(relay["relay_port"])
	_relays.erase(key)
