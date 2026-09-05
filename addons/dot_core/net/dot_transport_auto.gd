@tool
class_name DotTransportAuto
extends DotTransport

## Picks a transport from what the build can do and who needs to connect.
##
## The right default for a project that has not decided yet, and a reasonable
## permanent choice for one whose audience varies by build. It delegates to a
## real [DotTransportWebSocket] or [DotTransportENet] and logs which and why, so
## the decision is visible in the server log rather than inferred.
##
## The rule, in order:
##
## 1. Running in a browser, or [member require_web_clients] set → WebSocket.
##    A browser has no alternative and a server that wants browser clients has
##    no alternative either.
## 2. No UDP available → WebSocket.
## 3. Otherwise → ENet, for the unreliable channels.
##
## [member require_web_clients] is the one an operator actually sets, and it
## belongs in the server config: "will anyone play this in a browser" is not
## something the process can work out about its own future clients.

@export_group("Selection")

## Force WebSocket even where ENet is available.
##
## Set this on a server whose players include browser builds. Without it, a
## desktop-only server picks ENet and every browser client silently fails to
## connect — the single most confusing failure in this whole family, because
## nothing is misconfigured from the server's point of view.
@export var require_web_clients: bool = true

## Sub-transport used when WebSocket is chosen. Created with defaults if unset.
@export var websocket: DotTransportWebSocket = null

## Sub-transport used when ENet is chosen. Created with defaults if unset.
@export var enet: DotTransportENet = null

var _chosen: DotTransport = null
var _reason: String = ""


func _transport_name() -> String:
	var c := _resolve()
	return "Auto(%s)" % c._transport_name() if c != null else "Auto"


## The transport this would use, creating it if needed.
func _resolve() -> DotTransport:
	if _chosen != null:
		return _chosen

	if DotPlatform.is_web():
		_reason = "running in a browser"
		_chosen = _websocket()
	elif require_web_clients:
		_reason = "require_web_clients is set"
		_chosen = _websocket()
	elif not DotPlatform.has_udp():
		_reason = "no UDP on this platform"
		_chosen = _websocket()
	else:
		_reason = "native-only, ENet preferred"
		_chosen = _enet()

	# Limits live on this resource so an operator sets them once, not once per
	# sub-transport they might not know exists.
	_chosen.max_clients = max_clients
	_chosen.in_bandwidth = in_bandwidth
	_chosen.out_bandwidth = out_bandwidth
	_chosen.connect_timeout_sec = connect_timeout_sec

	DotLog.info(
		CHANNEL,
		"selected transport",
		{"transport": _chosen._transport_name(), "reason": _reason}
	)

	return _chosen


func _websocket() -> DotTransportWebSocket:
	if websocket == null:
		websocket = DotTransportWebSocket.new()
	return websocket


func _enet() -> DotTransportENet:
	if enet == null:
		enet = DotTransportENet.new()
	return enet


## Discards the cached choice so the next call re-decides.
##
## For a server that toggles [member require_web_clients] at runtime via a cvar;
## takes effect on the next listen, not on live connections.
func invalidate() -> void:
	_chosen = null
	_reason = ""


func supports_web_clients() -> bool:
	return _resolve().supports_web_clients()


func scheme() -> String:
	return _resolve().scheme()


func _is_available() -> DotResult:
	return _resolve()._is_available()


func _create_server(port: int, bind_address: String) -> DotResult:
	return _resolve()._create_server(port, bind_address)


func _create_client(address: String, port: int) -> DotResult:
	return _resolve()._create_client(address, port)


func describe() -> Dictionary:
	var d := _resolve().describe()
	d["auto_reason"] = _reason
	return d
