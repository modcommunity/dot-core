@tool
class_name DotTransportWebSocket
extends DotTransport

## WebSocket transport: the only one serving browser and native clients from one listener.
## TCP has head-of-line blocking ENet avoids, but a browser cannot speak ENet at all.
## An HTTPS page cannot open [code]ws://[/code] (mixed content), so browser clients need [code]wss://[/code]: see [member tls_cert]/[member tls_key], or terminate TLS at a proxy.

@export_group("TLS")

## Serve [code]wss://[/code] rather than [code]ws://[/code]; needs [member tls_cert] and [member tls_key].
## Leave off and terminate TLS at a reverse proxy if you run one: renewal is solved there.
@export var use_tls: bool = false

@export_file("*.crt", "*.pem") var tls_cert: String = ""
@export_file("*.key", "*.pem") var tls_key: String = ""

## Client-side: skip certificate verification. Development only.
## Logged at WARN on every use: an unverified connection nobody notices is how a debug flag reaches production.
@export var tls_trust_all: bool = false

## Client-side: verify against this CA bundle instead of the system store.
## For self-signed certificates on a LAN; the honest alternative to [member tls_trust_all].
@export_file("*.crt", "*.pem") var tls_ca_bundle: String = ""

@export_group("WebSocket")

## Path the server accepts and clients request.
## Distinct from [code]/[/code] so a reverse proxy can route game and website on one hostname (same-origin, no CORS).
@export var path: String = "/game"

## Subprotocols offered in the handshake.
## Doubles as a version gate: an incompatible client is refused at the handshake instead of desynchronising later.
@export var handshake_protocols: PackedStringArray = PackedStringArray(["dot.v1"])

## Seconds to complete the WebSocket handshake.
@export_range(0.5, 60.0, 0.5) var handshake_timeout_sec: float = 5.0

@export_group("Buffers")

## Per-peer inbound buffer, as a power-of-two exponent (16 = 64 KiB).
## Must exceed the largest packet (dot-cloud content chunks); too small shows as a disconnect mid-download.
@export_range(10, 24, 1) var inbound_buffer_exp: int = 16

@export_range(10, 24, 1) var outbound_buffer_exp: int = 16

## Packets queued per peer before new ones are dropped.
@export_range(16, 8192, 1) var max_queued_packets: int = 2048


func _transport_name() -> String:
	return "WebSocket"


func supports_web_clients() -> bool:
	return true


func scheme() -> String:
	return "wss" if use_tls else "ws"


func _is_available() -> DotResult:
	if not DotPlatform.has_websocket():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This build has no WebSocketMultiplayerPeer."
		)
	return DotResult.success(true)


func _create_server(port: int, bind_address: String) -> DotResult:
	var peer := WebSocketMultiplayerPeer.new()
	_configure(peer)

	var tls: TLSOptions = null
	if use_tls:
		var built := _build_server_tls()
		if not built.ok:
			return built
		tls = built.value

	var err := peer.create_server(port, bind_address, tls)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(
				err, "listening on %s:%d" % [bind_address, port]
			)
		)

	return DotResult.success(peer)


func _create_client(address: String, port: int) -> DotResult:
	var url := build_url(address, port)

	var peer := WebSocketMultiplayerPeer.new()
	_configure(peer)

	var tls := _build_client_tls()

	if tls_trust_all and url.begins_with("wss"):
		DotLog.warn(
			CHANNEL,
			"connecting with certificate verification DISABLED",
			{"url": url}
		)

	var err := peer.create_client(url, tls)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "connecting to %s" % url)
		)

	return DotResult.success(peer)


## Turns a user-typed address into the URL [method WebSocketMultiplayerPeer.create_client] needs.
## Fills scheme, port and path from this transport's settings: an explicit port wins, then the scheme, then the defaults.
## On an HTTPS page an explicit [code]ws://[/code] is upgraded to [code]wss://[/code]: the browser would refuse it anyway.
func build_url(address: String, port: int = 0) -> String:
	# Parsed with a sentinel of 0 so that "the address named no port" is
	# distinguishable from "the address named the default", which is what decides
	# whether the scheme gets to choose one below.
	var parts := DotTransport.normalise_address(address, 0)

	if str(parts["scheme"]) == "":
		parts["scheme"] = scheme()
	elif str(parts["scheme"]) == "http":
		parts["scheme"] = "ws"
	elif str(parts["scheme"]) == "https":
		parts["scheme"] = "wss"

	# The port follows the SCHEME, not this transport's own `use_tls` (which is about the socket it serves).
	# Else `wss://host/game` dialled 27015 and failed as "could not reach the server".
	if int(parts["port"]) <= 0:
		if port > 0:
			parts["port"] = port
		elif str(parts["scheme"]) == "wss":
			parts["port"] = 443
		else:
			parts["port"] = _default_port()

	if str(parts["path"]) == "":
		parts["path"] = path

	# [method DotWeb.is_https_page], not [method DotWeb.is_secure_context]: localhost is a secure context on plain HTTP, but mixed-content blocking exempts it too.
	# Asking the wrong one upgraded every local page to wss:// against a server with no certificate.
	if str(parts["scheme"]) == "ws" and DotWeb.is_https_page():
		DotLog.warn(
			CHANNEL,
			"upgrading ws:// to wss:// — a page served over HTTPS may not open an "
			+ "insecure socket",
			{"host": str(parts["host"])}
		)
		parts["scheme"] = "wss"

	return DotTransport.format_address(parts)


## The port when neither the caller nor the address named one and the scheme implies none.
## [member use_tls] suits opening a server, not dialling one, hence [method build_url] asks the scheme first.
func _default_port() -> int:
	return 443 if use_tls else 27015


func _configure(peer: WebSocketMultiplayerPeer) -> void:
	peer.handshake_timeout = handshake_timeout_sec
	peer.supported_protocols = handshake_protocols
	peer.inbound_buffer_size = 1 << inbound_buffer_exp
	peer.outbound_buffer_size = 1 << outbound_buffer_exp
	peer.max_queued_packets = max_queued_packets


func _build_server_tls() -> DotResult:
	if tls_cert == "" or tls_key == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"use_tls needs both tls_cert and tls_key.",
			"or terminate TLS at a reverse proxy and leave use_tls off"
		)

	var cert := load(tls_cert) as X509Certificate
	if cert == null:
		return DotResult.fail(
			DotError.CODE_IO, "Could not load certificate.", tls_cert
		)

	var key := load(tls_key) as CryptoKey
	if key == null:
		return DotResult.fail(
			DotError.CODE_IO, "Could not load private key.", tls_key
		)

	return DotResult.success(TLSOptions.server(key, cert))


func _build_client_tls() -> TLSOptions:
	if tls_trust_all:
		return TLSOptions.client_unsafe()

	if tls_ca_bundle != "":
		var ca := load(tls_ca_bundle) as X509Certificate
		if ca != null:
			return TLSOptions.client(ca)
		DotLog.warn(
			CHANNEL,
			"could not load CA bundle; falling back to the system store",
			{"path": tls_ca_bundle}
		)

	# null means "use the system trust store", which is what a public
	# certificate needs and what browsers do regardless of what we pass.
	return TLSOptions.client()


func describe() -> Dictionary:
	var d := super.describe()
	d["tls"] = use_tls
	d["path"] = path
	d["protocols"] = Array(handshake_protocols)
	return d
