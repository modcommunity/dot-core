@tool
class_name DotTransport
extends Resource

## Base class for a swappable multiplayer transport. The browser has no UDP, so ENet is
## absent there: the choice is a deployment decision in a [Resource], not a code one.
## A server for both audiences uses [DotTransportDual]; a client uses ENet or WebSocket
## ([DotTransportAuto] if undecided). Subclasses implement [method _create_server] and
## [method _create_client], returning a [MultiplayerPeer] in a [DotResult].

const CHANNEL := "transport"

## Channel budget shared by every transport, so a 4 MB content chunk on its own channel
## does not head-of-line block a movement update. dot-server assigns these.
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

## Maximum simultaneous clients, enforced where the transport can. dot-server enforces its
## own limit too: a transport refusal gives no reason, and reserve slots decide after connect.
@export_range(1, 4096, 1) var max_clients: int = 32

## Inbound bandwidth cap in bytes/sec. 0 is unlimited.
@export var in_bandwidth: int = 0

## Outbound bandwidth cap in bytes/sec. 0 is unlimited.
@export var out_bandwidth: int = 0

@export_group("Timeouts")

## Seconds to wait for a connection to establish before giving up.
@export_range(1.0, 120.0, 0.5) var connect_timeout_sec: float = 15.0



## Creates a listening peer. Returns a [MultiplayerPeer] in the result.
func _create_server(port: int, bind_address: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL,
		"%s does not implement _create_server()." % _transport_name()
	)


## Creates a connecting peer. [param address] is transport-specific (a host for ENet, a URL
## for WebSocket); [method normalise_address] makes a typed string usable by either.
func _create_client(address: String, port: int) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL,
		"%s does not implement _create_client()." % _transport_name()
	)


func _transport_name() -> String:
	return "DotTransport"


## Whether this transport can run on the current build, so the failure is "cannot host over
## ENet" at boot and not a null peer later.
func _is_available() -> DotResult:
	return DotResult.success(true)


## Whether browser clients can connect to a server using this transport.
func supports_web_clients() -> bool:
	return false


## The URL scheme this transport advertises, for connect strings and server
## listings. Empty when it does not use URLs.
func scheme() -> String:
	return ""



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


## Splits a user-typed connect string (host, host:port, ws://, wss://, [code][::1]:27015[/code])
## into [code]{scheme, host, port, path}[/code], defaulting to [param default_port].
## Bracketed IPv6 is explicit: splitting on the last colon turns [code]::1[/code] into a bad host.
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
