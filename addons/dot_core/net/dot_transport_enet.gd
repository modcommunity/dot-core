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

	var err: int = peer.call(
		"create_server",
		port,
		max_clients,
		channel_count,
		in_bandwidth,
		out_bandwidth
	)

	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "listening on UDP port %d" % port)
		)

	_apply_compression(peer)
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


func describe() -> Dictionary:
	var d := super.describe()
	d["channels"] = channel_count
	d["compression"] = compression_mode
	return d
