@tool
class_name DotTransport
extends Resource

## Base class for a swappable multiplayer transport.
##
## [b]Why this abstraction exists.[/b] The dot-* family must serve desktop,
## mobile and browser clients, and the browser has no UDP — so [ENetMultiplayerPeer]
## is not merely slow there, it is absent from the export template. Meanwhile
## ENet is the better choice when no browser is involved. That is a deployment
## decision, not a code decision, so it belongs in a [Resource] an operator can
## swap without touching a script.
##
## [b]The consequence you cannot design around.[/b] A single listening socket
## speaks one protocol. A server that must accept browser clients must listen on
## WebSocket, and then its desktop clients also speak WebSocket. There is no
## "ENet for desktop, WebSocket for web" on one port; running both means two
## listeners and two [MultiplayerAPI] instances, which is a different (and much
## larger) program than this addon is. So:
##
## [codeblock]
## browser clients needed?  ->  DotTransportWebSocket, everywhere
## desktop/mobile only?     ->  DotTransportENet, for the lower overhead
## [/codeblock]
##
## [DotTransportAuto] picks between them from what the build can do, which is the
## right default for a project that has not decided yet.
##
## Subclasses implement [method _create_server] and [method _create_client] and
## return a [MultiplayerPeer] wrapped in a [DotResult].

const CHANNEL := "transport"

## Channel budget shared by every transport.
##
## Reliable game state, unreliable snapshots, chat/console, and bulk content
## transfer each want different delivery guarantees, and mixing them on one
## channel means a 4 MB content chunk head-of-line blocks a movement update.
## dot-server assigns these; dot-cloud's in-band source uses [constant CHANNEL_CONTENT].
enum Channel {
	## Handshake, authentication, console commands. Reliable, ordered.
	CONTROL = 0,
	## Gameplay state replication.
	STATE = 1,
	## Chat and events.
	EVENT = 2,
	## Bulk content transfer. Deliberately last so it never starves the others.
	CONTENT = 3,
}

## Total channels every transport allocates.
const CHANNEL_COUNT := 4

@export_group("Identity")

## Human-readable name for logs and the `status` command.
@export var display_name: String = ""

@export_group("Limits")

## Maximum simultaneous clients, enforced by the transport where it can be.
##
## dot-server enforces its own limit too, because a transport-level refusal
## gives the client no reason for the rejection and admin reserve slots need to
## admit a connection before deciding.
@export_range(1, 4096, 1) var max_clients: int = 32

## Inbound bandwidth cap in bytes/sec. 0 is unlimited.
@export var in_bandwidth: int = 0

## Outbound bandwidth cap in bytes/sec. 0 is unlimited.
@export var out_bandwidth: int = 0

@export_group("Timeouts")

## Seconds to wait for a connection to establish before giving up.
@export_range(1.0, 120.0, 0.5) var connect_timeout_sec: float = 15.0


# --- Subclass interface ----------------------------------------------------

## Creates a listening peer. Returns a [MultiplayerPeer] in the result.
func _create_server(port: int, bind_address: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL,
		"%s does not implement _create_server()." % _transport_name()
	)


## Creates a connecting peer.
##
## [param address] is transport-specific: a host for ENet, a full URL for
## WebSocket. [method normalise_address] makes a user-typed string usable by
## either, so callers can accept one field in a UI.
func _create_client(address: String, port: int) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL,
		"%s does not implement _create_client()." % _transport_name()
	)


func _transport_name() -> String:
	return "DotTransport"


## Whether this transport can run on the current build.
##
## Checked before use so the failure is "this build cannot host over ENet"
## at boot rather than a null peer three calls later.
func _is_available() -> DotResult:
	return DotResult.success(true)


## Whether browser clients can connect to a server using this transport.
func supports_web_clients() -> bool:
	return false


## The URL scheme this transport advertises, for connect strings and server
## listings. Empty when it does not use URLs.
func scheme() -> String:
	return ""


# --- Public API ------------------------------------------------------------

## Creates a listening peer, after checking the platform can do it.
func create_server(port: int, bind_address: String = "*") -> DotResult:
	if not DotPlatform.can_listen():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This platform cannot listen for connections.",
			"a browser tab has no listening sockets; host on desktop and "
			+ "connect from the browser as a client"
		)

	var avail := _is_available()
	if not avail.ok:
		return avail

	if port < 0 or port > 65535:
		return DotResult.fail(
			DotError.CODE_INVALID, "Port %d is out of range." % port
		)

	var res := _create_server(port, bind_address)
	if res.ok:
		DotLog.info(
			CHANNEL,
			"listening",
			{
				"transport": _transport_name(),
				"port": port,
				"bind": bind_address,
				"web_clients": supports_web_clients(),
			}
		)
	return res


func create_client(address: String, port: int = 0) -> DotResult:
	var avail := _is_available()
	if not avail.ok:
		return avail

	if address.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "No address given.")

	var res := _create_client(address, port)
	if res.ok:
		DotLog.info(
			CHANNEL,
			"connecting",
			{"transport": _transport_name(), "address": address, "port": port}
		)
	return res


## Splits a user-typed connect string into its parts.
##
## Accepts everything a player might paste: [code]1.2.3.4[/code],
## [code]1.2.3.4:27015[/code], [code]ws://host/path[/code],
## [code]wss://host:443[/code], [code][::1]:27015[/code]. Returns
## [code]{scheme, host, port, path}[/code] with the port defaulted to
## [param default_port] when absent.
##
## Bracketed IPv6 is handled explicitly because splitting on the last colon —
## the obvious implementation — turns [code]::1[/code] into host [code]:[/code]
## and port [code]1[/code], and the resulting failure looks like a network
## problem rather than a parsing bug.
static func normalise_address(
	raw: String,
	default_port: int
) -> Dictionary:
	var s := raw.strip_edges()
	var out := {
		"scheme": "",
		"host": "",
		"port": default_port,
		"path": "",
	}

	var scheme_end := s.find("://")
	if scheme_end > 0:
		out["scheme"] = s.substr(0, scheme_end).to_lower()
		s = s.substr(scheme_end + 3)

	var slash := s.find("/")
	if slash >= 0:
		out["path"] = s.substr(slash)
		s = s.substr(0, slash)

	if s.begins_with("["):
		var close := s.find("]")
		if close < 0:
			out["host"] = s
			return out
		out["host"] = s.substr(1, close - 1)
		var rest := s.substr(close + 1)
		if rest.begins_with(":") and rest.substr(1).is_valid_int():
			out["port"] = rest.substr(1).to_int()
		return out

	# An unbracketed string with two or more colons is a bare IPv6 literal;
	# there is no port to find in it.
	if s.count(":") >= 2:
		out["host"] = s
		return out

	if s.contains(":"):
		var parts := s.split(":", true, 1)
		out["host"] = parts[0]
		if parts[1].is_valid_int():
			out["port"] = parts[1].to_int()
	else:
		out["host"] = s

	return out


## Rebuilds a canonical connect string, for server listings and reconnects.
static func format_address(parts: Dictionary, include_scheme: bool = true) -> String:
	var host := str(parts.get("host", ""))
	if host.contains(":") and not host.begins_with("["):
		host = "[%s]" % host

	var s := ""
	if include_scheme and str(parts.get("scheme", "")) != "":
		s += "%s://" % parts["scheme"]

	s += host

	var port := int(parts.get("port", 0))
	if port > 0:
		s += ":%d" % port

	s += str(parts.get("path", ""))
	return s


func describe() -> Dictionary:
	return {
		"transport": _transport_name(),
		"name": display_name,
		"max_clients": max_clients,
		"web_clients": supports_web_clients(),
		"scheme": scheme(),
		"available": _is_available().ok,
	}
