class_name DotTcpScreen
extends RefCounted

## The public TCP port of a plain WebSocket listener, answering a TLS ClientHello with a
## close instead of silence.
##
## [b]Why this exists.[/b] A native client dials a bare [code]host:port[/code] as
## [code]wss://[/code] first (dot-server's client link: a public game port is normally a TLS
## port). Against a server with no certificate that ClientHello reached the engine's
## WebSocket server, which reads the HTTP request header in C++ until it sees CRLFCRLF or its
## handshake timeout passes. A ClientHello has no CRLFCRLF, so every wrong guess cost the
## client its whole TLS timeout (2.5 s) before it tried [code]ws://[/code].
##
## [b]Why a relay and not a peek.[/b] The obvious fix is to look at byte 0 and hand the
## socket on. Godot cannot: [StreamPeerTCP] has no peek, a byte read is gone, and
## [method WebSocketPeer.accept_stream] refuses any stream but a [StreamPeerTCP] or
## [StreamPeerTLS] (a [StreamPeerExtension] that replays the byte is ERR_INVALID_PARAMETER).
## So, like [DotUdpDemux] for UDP, this owns the public port:
##
## [codeblock]
## connection on the public port, byte 0
##   'G' and a complete header with Upgrade: websocket -> relayed, both ways, to the
##       unchanged WebSocketMultiplayerPeer on 127.0.0.1:<inner port>
##   'G' without that header (a scanner's "GET /")     -> answered 426 and closed
##   anything else (0x16: a TLS handshake record)      -> closed at once
## [/codeblock]
##
## [b]The relay hides the client's address[/b]: the WebSocket server sees 127.0.0.1 and
## the relay's own ephemeral port. [method remote_for_inner_port] maps that port back, and
## [DotDualPeer] answers [code]get_peer_address[/code] / [code]get_peer_port[/code] with the
## real remote, so bans, rate limits and logs keep working.
##
## [b]No threads.[/b] [method pump_in] and [method pump_out] run inside the peer's poll on
## the main thread, around the WebSocket server's own poll, so a packet crosses the relay
## in the same poll it would have crossed the socket: no frame of latency is added.
## [b]Back-pressure is kept[/b]: neither side is read while more than [member max_buffered]
## bytes wait for the other, so a client that stops reading still fills the WebSocket
## server's outbound buffer and is closed by it, as it was without the relay.

const CHANNEL := "transport"

## The first byte of every WebSocket handshake ("GET ...").
const HTTP_GET_FIRST := 0x47
## The first byte of a TLS handshake record, i.e. a ClientHello.
const TLS_HANDSHAKE := 0x16
## Largest request header held while waiting for its blank line. A real handshake is a few
## hundred bytes; more than this is not one, and holding it would let a scanner pin memory.
const MAX_HEADER_BYTES := 8192
const HEADER_END := "\r\n\r\n"

## Seconds a connection may stay silent before its first byte. Same default as the
## WebSocket handshake timeout, which governs it from there on.
var first_byte_timeout_sec: float = 5.0

## Most connections at once, waiting or relayed. Bounds the sockets a flood can open.
var max_links: int = 256

## Bytes held for one direction of one link before that side stops being read.
var max_buffered: int = 1 << 18

var _server: TCPServer = null
var _public_port: int = 0
var _inner_port: int = 0

## Connections whose request header is not complete yet: {outer, since, buf}.
var _waiting: Array[Dictionary] = []
## Relayed connections: {outer, inner, to_inner, to_outer, ip, port, inner_port}.
var _links: Array[Dictionary] = []
## Inner (relay-side) local port -> link.
var _by_inner_port: Dictionary = {}

var _relayed: int = 0
var _refused: int = 0
var _refused_tls: int = 0
var _refused_http: int = 0
var _timed_out: int = 0
var _over_limit: int = 0


## Listens on the public [param port]. [param inner_port] is the loopback port the
## WebSocket server listens on.
func open(port: int, bind_address: String, inner_port: int) -> DotResult:
	_server = TCPServer.new()
	var bind := bind_address if bind_address != "" else "*"
	var err := _server.listen(port, bind)
	if err != OK:
		_server = null
		return DotResult.failure(DotError.from_engine(err, "listening on TCP %s:%d" % [bind, port]))
	_public_port = _server.get_local_port()
	_inner_port = inner_port
	return DotResult.success(_public_port)


func is_open() -> bool:
	return _server != null


func public_port() -> int:
	return _public_port


func inner_port() -> int:
	return _inner_port


## Sets the loopback port relayed connections go to. For a WebSocket server started after
## [method open], once the public port is held.
func set_inner_port(port: int) -> void:
	_inner_port = port


## Accepts, screens first bytes, and moves client bytes towards the WebSocket server. Call
## before the WebSocket server's poll.
func pump_in() -> void:
	if _server == null:
		return
	_accept()
	_screen()
	# No poll here: status is pump_out's, once per link per poll, and a socket's poll is a
	# system call.
	for link: Dictionary in _links:
		var inner: StreamPeerTCP = link["inner"]
		var outer: StreamPeerTCP = link["outer"]
		if inner.get_status() == StreamPeerTCP.STATUS_CONNECTING:
			inner.poll()
		link["to_inner"] = _read_into(outer, link["to_inner"])
		link["to_inner"] = _write_from(inner, link["to_inner"])


## Moves the WebSocket server's bytes back to the clients and closes links either side
## has left. Call after the WebSocket server's poll.
func pump_out() -> void:
	if _server == null:
		return
	var gone: Array[Dictionary] = []
	for link: Dictionary in _links:
		var inner: StreamPeerTCP = link["inner"]
		var outer: StreamPeerTCP = link["outer"]
		inner.poll()
		var inner_status := inner.get_status()
		if inner_status == StreamPeerTCP.STATUS_CONNECTED:
			link["to_outer"] = _read_into(inner, link["to_outer"])
		link["to_outer"] = _write_from(outer, link["to_outer"])
		outer.poll()
		var outer_status := outer.get_status()
		var inner_done := inner_status == StreamPeerTCP.STATUS_NONE or inner_status == StreamPeerTCP.STATUS_ERROR
		var outer_done := outer_status != StreamPeerTCP.STATUS_CONNECTED
		if inner_done or outer_done:
			gone.append(link)
	for link in gone:
		_close_link(link)


## Moves what the WebSocket server has written since the last pump back to the clients, and
## nothing else. [b]Its sends do not wait for its poll[/b]: the engine's WebSocket peer writes
## a packet to the socket inside put_packet, so without this a server's packet reached the
## client a frame later than unscreened. [DotDualPeer] calls it deferred, once per frame
## that sent anything.
func flush() -> void:
	for link: Dictionary in _links:
		var inner: StreamPeerTCP = link["inner"]
		link["to_outer"] = _read_into(inner, link["to_outer"])
		link["to_outer"] = _write_from(link["outer"], link["to_outer"])


## The remote a relayed connection stands for, by the port the WebSocket server sees it
## on: {ip, port}, or empty for a port that is not one of this screen's links.
func remote_for_inner_port(port: int) -> Dictionary:
	var link: Dictionary = _by_inner_port.get(port, {})
	if link.is_empty():
		return {}
	return {"ip": link["ip"], "port": link["port"]}


func link_count() -> int:
	return _links.size()


func waiting_count() -> int:
	return _waiting.size()


func close() -> void:
	for entry in _waiting:
		(entry["outer"] as StreamPeerTCP).disconnect_from_host()
	_waiting.clear()
	for link in _links.duplicate():
		_close_link(link)
	if _server != null:
		_server.stop()
		_server = null


func describe() -> Dictionary:
	return {
		"port": _public_port,
		"inner_port": _inner_port,
		"links": _links.size(),
		"waiting": _waiting.size(),
		"relayed": _relayed,
		"refused": _refused,
		"refused_tls": _refused_tls,
		"refused_http": _refused_http,
		"timed_out": _timed_out,
		"over_limit": _over_limit,
	}


# --- Internals ---------------------------------------------------------------

func _accept() -> void:
	while _server.is_connection_available():
		var outer := _server.take_connection()
		if outer == null:
			return
		if _waiting.size() + _links.size() >= max_links:
			_over_limit += 1
			outer.disconnect_from_host()
			continue
		_waiting.append({"outer": outer, "since": Time.get_ticks_msec(), "buf": PackedByteArray()})


func _screen() -> void:
	if _waiting.is_empty():
		return
	var now := Time.get_ticks_msec()
	var still: Array[Dictionary] = []
	for entry: Dictionary in _waiting:
		var outer: StreamPeerTCP = entry["outer"]
		outer.poll()
		if outer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var available := outer.get_available_bytes()
		if available > 0:
			var got: Array = outer.get_partial_data(mini(available, MAX_HEADER_BYTES))
			var data: PackedByteArray = got[1]
			if got[0] != OK or data.is_empty():
				outer.disconnect_from_host()
				continue
			# Packed arrays copy on assignment: append to a local and store it back.
			var held: PackedByteArray = entry["buf"]
			held.append_array(data)
			entry["buf"] = held
		var buf: PackedByteArray = entry["buf"]
		if not buf.is_empty():
			if buf[0] != HTTP_GET_FIRST:
				_refuse(outer, buf[0])
				continue
			# The engine's WebSocket server raises an ERROR it cannot be told to lower for a
			# GET without Upgrade: websocket (an internet scanner's "GET /"), so the header
			# is read whole here and only a real handshake is handed on.
			var head := buf.get_string_from_ascii()
			var end := head.find(HEADER_END)
			if end >= 0:
				if _is_websocket_upgrade(head.substr(0, end)):
					_open_link(outer, buf)
				else:
					_refuse_http(outer, buf)
				continue
			if buf.size() >= MAX_HEADER_BYTES:
				_refuse_http(outer, buf)
				continue
		if now - int(entry["since"]) > int(first_byte_timeout_sec * 1000.0):
			_timed_out += 1
			if not buf.is_empty():
				# A truncated request: closed here rather than left for the engine's own
				# handshake timeout to report.
				DotLog.debug(CHANNEL, "closed a truncated request header", {"ip": outer.get_connected_host(), "bytes": buf.size()})
			outer.disconnect_from_host()
		else:
			still.append(entry)
	_waiting = still


func _refuse(outer: StreamPeerTCP, first: int) -> void:
	_refused += 1
	if first == TLS_HANDSHAKE:
		_refused_tls += 1
	DotLog.debug(
		CHANNEL,
		"closed a connection that is not a WebSocket handshake",
		{"ip": outer.get_connected_host(), "first_byte": first, "tls": first == TLS_HANDSHAKE}
	)
	outer.disconnect_from_host()


## True when the header block has an [code]Upgrade[/code] header whose value contains
## "websocket" (a token list, any case), which is all a WebSocket handshake needs to be.
func _is_websocket_upgrade(head: String) -> bool:
	for line in head.split("\r\n"):
		var colon := line.find(":")
		if colon > 0 and line.substr(0, colon).strip_edges().to_lower() == "upgrade":
			return line.substr(colon + 1).to_lower().contains("websocket")
	return false


func _refuse_http(outer: StreamPeerTCP, request: PackedByteArray) -> void:
	_refused += 1
	_refused_http += 1
	var line := request.get_string_from_ascii().get_slice("\r\n", 0).left(80)
	DotLog.debug(
		CHANNEL,
		"closed a plain HTTP request that is not a WebSocket upgrade",
		{"ip": outer.get_connected_host(), "request": line}
	)
	# 426 names the fix to a human who opened the port in a browser; the connection closes
	# either way, so a scanner learns nothing it could use.
	outer.put_data("HTTP/1.1 426 Upgrade Required\r\nUpgrade: websocket\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".to_utf8_buffer())
	outer.disconnect_from_host()


func _open_link(outer: StreamPeerTCP, first: PackedByteArray) -> void:
	var inner := StreamPeerTCP.new()
	var err := inner.connect_to_host("127.0.0.1", _inner_port)
	if err != OK:
		DotLog.warn(
			CHANNEL,
			"could not reach the WebSocket server on loopback; dropping a client",
			{"inner_port": _inner_port, "error": error_string(err)}
		)
		outer.disconnect_from_host()
		return
	var link := {
		"outer": outer,
		"inner": inner,
		"to_inner": first,
		"to_outer": PackedByteArray(),
		"ip": outer.get_connected_host(),
		"port": outer.get_connected_port(),
		"inner_port": inner.get_local_port(),
	}
	_links.append(link)
	_by_inner_port[int(link["inner_port"])] = link
	_relayed += 1


## Appends what [param from] has, while [param buffer] is under [member max_buffered].
func _read_into(from: StreamPeerTCP, buffer: PackedByteArray) -> PackedByteArray:
	# A socket its poll found closed errors on get_available_bytes; pump_out closes the link.
	var room := max_buffered - buffer.size()
	if room <= 0 or from.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return buffer
	var available := from.get_available_bytes()
	if available <= 0:
		return buffer
	var got: Array = from.get_partial_data(mini(available, room))
	if got[0] == OK:
		buffer.append_array(got[1])
	return buffer


## Writes as much of [param buffer] as [param to] takes and returns the rest.
func _write_from(to: StreamPeerTCP, buffer: PackedByteArray) -> PackedByteArray:
	if buffer.is_empty() or to.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return buffer
	var put: Array = to.put_partial_data(buffer)
	var sent := int(put[1]) if put[0] == OK else 0
	if sent <= 0:
		return buffer
	if sent >= buffer.size():
		return PackedByteArray()
	return buffer.slice(sent)


## Closes both ends of a link, giving each the bytes still owed to it first.
func _close_link(link: Dictionary) -> void:
	var inner: StreamPeerTCP = link["inner"]
	var outer: StreamPeerTCP = link["outer"]
	_write_from(outer, link["to_outer"])
	_write_from(inner, link["to_inner"])
	inner.disconnect_from_host()
	outer.disconnect_from_host()
	_links.erase(link)
	_by_inner_port.erase(int(link["inner_port"]))
