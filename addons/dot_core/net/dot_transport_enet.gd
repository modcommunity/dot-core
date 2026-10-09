@tool
class_name DotTransportENet
extends DotTransport

## ENet (UDP) transport — lower overhead, no browser clients.
##
## Prefer this when every client is desktop or mobile. Unreliable channels mean a
## dropped position update is skipped rather than retransmitted, which is exactly
## right for state that a newer packet supersedes and which TCP cannot express.
##
## [b]Browsers cannot connect to this, at all.[/b] Not "slowly" or "with a
## shim" — the web export template has no UDP sockets and no [ENetMultiplayerPeer]
## class. A server that needs both audiences must use [DotTransportWebSocket].
##
## [b]Note on how this file talks to ENet.[/b] Every call goes through
## [method ClassDB.instantiate] and [method Object.call] rather than naming
## [code]ENetMultiplayerPeer[/code]. That is not style: a web build has no such
## identifier, and a script mentioning one fails to compile there — which would
## make this file impossible to ship inside an addon that also supports web. The
## indirection costs a dictionary lookup at connect time and keeps one codebase.

## ENet's own limit. Exceeding it is a configuration error, not a resource one.
const ENET_MAX_PEERS := 4095

@export_group("ENet")

## Channels to allocate. See [enum DotTransport.Channel].
##
## Must match on client and server: ENet negotiates the minimum of the two, so a
## mismatch silently collapses the content channel onto a gameplay one.
@export_range(1, 32, 1) var channel_count: int = DotTransport.CHANNEL_COUNT

## Client-side local port to bind. 0 lets the OS choose.
##
## Set it only when a firewall rule needs a fixed source port; a fixed port also
## means two clients cannot run on one machine.
@export var client_local_port: int = 0

@export_group("Timeouts")

## When ENet gives up on a peer that is not acknowledging reliable traffic, applied to every
## peer on both ends as it connects ([code]ENetPacketPeer.set_timeout[/code]).
##
## [b]ENet's own defaults drop a player on a bad patch, not on a dead link.[/b] They are a
## limit of 32 and a minimum of 5 s: once one reliable command has been resent with its
## timeout doubled five times, and five seconds have passed, the peer is disconnected
## (thirdparty/enet/protocol.c, the `timeoutLimit` test). A resend fails if the data OR its
## acknowledgement is lost, so at 20% loss each way that is a 36% chance per try and six
## in a row is about one reliable command in five hundred: game-arena's headless_lossy saw
## the server drop a player who was still sending every tick about one run in four. A
## server here already decides for itself when a silent client is gone
## (dot-server's client_timeout_sec, 60 s), so the transport's job is only to notice a
## link that is really dead. The limit is set high enough that only
## [member peer_timeout_max_ms] decides: a reliable command unacknowledged that long.
@export_range(1, 65536, 1) var peer_timeout_limit: int = 1024

## See [member peer_timeout_limit]. Only matters when the limit is reached first.
@export_range(1000, 120000, 500) var peer_timeout_min_ms: int = 10000

## A reliable command unacknowledged for this long ends the connection, whatever else.
@export_range(1000, 120000, 500) var peer_timeout_max_ms: int = 30000

@export_group("Compression")

## ENet's built-in compression mode.
##
## [constant ENetConnection.COMPRESS_RANGE_CODER] is the usual choice and is
## Godot's default. Compression must match on both ends — a mismatch presents as
## a connection that establishes and then delivers garbage, which is a
## memorably bad afternoon.
@export_enum(
	"None:0",
	"RangeCoder:1",
	"FastLZ:2",
	"ZLib:3",
	"Zstd:4"
) var compression_mode: int = 1


func _transport_name() -> String:
	return "ENet"


func supports_web_clients() -> bool:
	return false


func scheme() -> String:
	return "udp"


func _is_available() -> DotResult:
	if DotPlatform.is_web():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"Browsers cannot use ENet.",
			"the web export has no UDP sockets; use DotTransportWebSocket"
		)

	if not ClassDB.class_exists("ENetMultiplayerPeer"):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This build has no ENetMultiplayerPeer."
		)

	return DotResult.success(true)


func _create_server(port: int, bind_address: String) -> DotResult:
	if max_clients > ENET_MAX_PEERS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"ENet allows at most %d peers." % ENET_MAX_PEERS,
			"max_clients is %d" % max_clients
		)

	var peer := _new_peer()
	if peer == null:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "Could not create an ENet peer."
		)

	# set_bind_ip must precede create_server; afterwards the socket exists and
	# the setting is silently ignored.
	if bind_address != "" and bind_address != "*":
		peer.call("set_bind_ip", bind_address)

	# [b]0 channels, on purpose, and it is not a channel count.[/b] The engine's
	# `create_server` hands its channel argument to ENet as the host's INCOMING
	# BANDWIDTH and passes 0 as the channel limit (`create_host_bound(bind_ip, port,
	# max_clients, 0, max_channels + SYSCH_MAX, out_bandwidth)`), and `in_bandwidth`
	# is never used. With our four channels a server told every client it could take
	# six bytes a second, and the client's ENet believed it: its throttle limit fell to
	# 1/32 within the first second of traffic and most unreliable packets -- every
	# client's commands -- were dropped until the server's own correction and then the
	# throttle's slow climb, up to twenty seconds. Passing 0 changes only that slot: the
	# channel limit is ENet's maximum either way, and a client still asks for
	# `channel_count`. `dual_transport_selftest` measures it on a real pair.
	var err: int = peer.call(
		"create_server",
		port,
		max_clients,
		0,
		in_bandwidth,
		out_bandwidth
	)

	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "listening on UDP port %d" % port)
		)

	_apply_compression(peer)
	_apply_timeouts_on_connect(peer)
	return DotResult.success(peer as MultiplayerPeer)


func _create_client(address: String, port: int) -> DotResult:
	var parts := DotTransport.normalise_address(
		address, port if port > 0 else 27015
	)

	var host := str(parts["host"])
	var target_port := int(parts["port"])

	if host == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "No host in '%s'." % address
		)

	var peer := _new_peer()
	if peer == null:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "Could not create an ENet peer."
		)

	var err: int = peer.call(
		"create_client",
		host,
		target_port,
		channel_count,
		in_bandwidth,
		out_bandwidth,
		client_local_port
	)

	if err != OK:
		return DotResult.failure(
			DotError.from_engine(
				err, "connecting to %s:%d" % [host, target_port]
			)
		)

	_apply_compression(peer)
	_apply_timeouts_on_connect(peer)
	return DotResult.success(peer as MultiplayerPeer)


func _new_peer() -> Object:
	if not ClassDB.class_exists("ENetMultiplayerPeer"):
		return null
	return ClassDB.instantiate("ENetMultiplayerPeer")


## Applies compression to the peer's underlying [ENetConnection].
##
## Reached dynamically for the same reason as everything else here. A failure is
## logged rather than fatal: an uncompressed connection works, it just costs more
## bandwidth, and taking a server down over it would be the wrong trade.
func _apply_compression(peer: Object) -> void:
	if not peer.has_method("get_host"):
		return

	var host: Object = peer.call("get_host")
	if host == null or not host.has_method("compress"):
		return

	host.call("compress", compression_mode)
	DotLog.debug(
		CHANNEL, "enet compression set", {"mode": compression_mode}
	)


## Gives every peer [member peer_timeout_limit] and friends as it connects. On a server that
## is each client; on a client, the server (id 1). Connected rather than applied once,
## because a peer's [code]ENetPacketPeer[/code] exists only from its connection on.
func _apply_timeouts_on_connect(peer: Object) -> void:
	if not peer.has_signal("peer_connected") or not peer.has_method("get_peer"):
		return

	# A weak reference and a static function, not a lambda: a lambda capturing the peer and
	# connected to the peer's own signal is a reference cycle, and every server and client
	# made here leaked at exit. Static because the transport is often a temporary
	# (`DotTransportENet.new().create_client(...)`) that is gone before anybody connects.
	peer.connect("peer_connected", DotTransportENet._set_peer_timeout.bind(weakref(peer),
		peer_timeout_limit, peer_timeout_min_ms, peer_timeout_max_ms))


static func _set_peer_timeout(id: int, peer_ref: WeakRef, limit: int, low: int, high: int) -> void:
	var peer: Object = peer_ref.get_ref()
	if peer == null:
		return

	var packet_peer: Object = peer.call("get_peer", id)
	if packet_peer != null and packet_peer.has_method("set_timeout"):
		packet_peer.call("set_timeout", limit, low, high)


func describe() -> Dictionary:
	var d := super.describe()
	d["channels"] = channel_count
	d["compression"] = compression_mode
	d["peer_timeout"] = [peer_timeout_limit, peer_timeout_min_ms, peer_timeout_max_ms]
	return d
