@tool
class_name DotTransportAuto
extends DotTransport

## Picks a transport from what the build can do and who needs to connect, and logs which and
## why. A browser, [member require_web_clients] or no UDP gives WebSocket; otherwise ENet.
## [member require_web_clients] belongs in server config: the process cannot know its future clients.

@export_group("Selection")

## Force WebSocket even where ENet is available. Set it on a server with browser players, or
## every browser client silently fails to connect with nothing misconfigured server-side.
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


## Discards the cached choice so the next call re-decides; applies to the next listen only.
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
