@tool
class_name DotTransportENet
extends DotTransport

## ENet (UDP) transport: lower overhead, unreliable channels, no browser clients (the web template has no UDP or [ENetMultiplayerPeer]).
## Use [DotTransportWebSocket] when browsers must connect.
## Every ENet call goes through [method ClassDB.instantiate] and [method Object.call]: naming [code]ENetMultiplayerPeer[/code] fails to compile on web.

## ENet's own limit. Exceeding it is a configuration error, not a resource one.
const ENET_MAX_PEERS := 4095

## ENet's own throttle settings (ENET_PEER_PACKET_THROTTLE_*), for a control or a reset.
const ENET_DEFAULT_THROTTLE_INTERVAL_MS := 5000
const ENET_DEFAULT_THROTTLE_ACCELERATION := 2
const ENET_DEFAULT_THROTTLE_DECELERATION := 2

@export_group("ENet")

## Channels to allocate. See [enum DotTransport.Channel].
## Must match on both ends: ENet takes the minimum, so a mismatch collapses the content channel onto a gameplay one.
@export_range(1, 32, 1) var channel_count: int = DotTransport.CHANNEL_COUNT

## Client-side local port to bind. 0 lets the OS choose.
## Set only for a firewall rule needing a fixed source port; two clients then cannot share a machine.
@export var client_local_port: int = 0

@export_group("Timeouts")

## When ENet gives up on a peer not acknowledging reliable traffic, applied to every peer as it connects ([code]ENetPacketPeer.set_timeout[/code]).
## ENet's defaults (limit 32, min 5 s) drop a player on a bad patch, not a dead link; at 20% loss that was about one run in four.
## The limit is set high so only [member peer_timeout_max_ms] decides; dot-server's client_timeout_sec handles silent clients.
@export_range(1, 65536, 1) var peer_timeout_limit: int = 1024

## See [member peer_timeout_limit]. Only matters when the limit is reached first.
@export_range(1000, 120000, 500) var peer_timeout_min_ms: int = 10000

## A reliable command unacknowledged for this long ends the connection, whatever else.
@export_range(1000, 120000, 500) var peer_timeout_max_ms: int = 30000

@export_group("Packet throttle")

## How far ENet's packet throttle falls on each late acknowledgement, out of 32; 0 (default here) means it never falls.
## ENet's throttle drops unreliable packets at the SENDER and reads one slow frame as congestion: on a steady path a reliable burst took it to 0 and a client got 2-10% of snapshots at 0% loss.
## Nothing here wants it (state is superseded, dot-net budgets bytes); [constant ENET_DEFAULT_THROTTLE_DECELERATION] restores ENet's.
@export_range(0, 32, 1) var packet_throttle_deceleration: int = 0

## See [member packet_throttle_deceleration]. ENet's defaults.
@export_range(0, 32, 1) var packet_throttle_acceleration: int = ENET_DEFAULT_THROTTLE_ACCELERATION
@export_range(100, 60000, 100) var packet_throttle_interval_ms: int = ENET_DEFAULT_THROTTLE_INTERVAL_MS

@export_group("Compression")

## ENet's built-in compression mode ([constant ENetConnection.COMPRESS_RANGE_CODER] is the usual choice).
## Must match on both ends: a mismatch connects and then delivers garbage.
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

	# 0 channels on purpose: the engine's `create_server` passes this argument to ENet as INCOMING BANDWIDTH, not a channel count.
	# With four channels each client was told it could take six bytes a second and throttled itself to 1/32; `dual_transport_selftest` measures it.
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
## A failure is logged, not fatal: an uncompressed connection only costs bandwidth.
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


## Gives every peer [member peer_timeout_limit] and the packet throttle settings as it connects (each client on a server; the server on a client).
## Connected, not applied once: a peer's [code]ENetPacketPeer[/code] exists only from its connection on.
func _apply_timeouts_on_connect(peer: Object) -> void:
	if not peer.has_signal("peer_connected") or not peer.has_method("get_peer"):
		return

	# A weak reference and a static function, not a lambda: a capturing lambda on the peer's own signal is a reference cycle that leaked at exit.
	# Static because the transport is often a temporary gone before anybody connects.
	peer.connect("peer_connected", _set_peer_timeout.bind(weakref(peer),
		peer_timeout_limit, peer_timeout_min_ms, peer_timeout_max_ms,
		[packet_throttle_interval_ms, packet_throttle_acceleration, packet_throttle_deceleration]))


static func _set_peer_timeout(id: int, peer_ref: WeakRef, limit: int, low: int, high: int,
		throttle: Array = []) -> void:
	var peer: Object = peer_ref.get_ref()
	if peer == null:
		return

	var packet_peer: Object = peer.call("get_peer", id)
	if packet_peer != null and packet_peer.has_method("set_timeout"):
		packet_peer.call("set_timeout", limit, low, high)

	# See packet_throttle_deceleration. ENet sends it to the far end as well.
	if packet_peer != null and throttle.size() == 3 and packet_peer.has_method("throttle_configure"):
		packet_peer.call("throttle_configure", int(throttle[0]), int(throttle[1]), int(throttle[2]))


func describe() -> Dictionary:
	var d := super.describe()
	d["channels"] = channel_count
	d["compression"] = compression_mode
	d["peer_timeout"] = [peer_timeout_limit, peer_timeout_min_ms, peer_timeout_max_ms]
	d["packet_throttle"] = [packet_throttle_interval_ms, packet_throttle_acceleration, packet_throttle_deceleration]
	return d
