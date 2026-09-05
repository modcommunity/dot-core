@tool
class_name DotTransportWebSocket
extends DotTransport

## WebSocket transport — the only one that serves browser and native clients from
## one listener.
##
## [b]Choose this when any of your players use a browser build.[/b] It is TCP, so
## it has head-of-line blocking that ENet's unreliable channels avoid, and for a
## twitch shooter that difference is real. But a browser cannot speak ENet at all,
## so for anything browser-facing the comparison is not "WebSocket vs ENet", it is
## "WebSocket vs no web players".
##
## [b]TLS is not optional in practice.[/b] A page served over HTTPS may not open
## a [code]ws://[/code] socket — browsers block mixed content, and the failure
## surfaces only in the devtools console, which players do not read. So any
## server with browser clients on a real site needs [code]wss://[/code], meaning
## a certificate. See [member tls_cert] / [member tls_key], and prefer terminating
## TLS at a reverse proxy in production.

@export_group("TLS")

## Serve [code]wss://[/code] rather than [code]ws://[/code].
##
## Requires [member tls_cert] and [member tls_key]. Leave off and terminate TLS
## at nginx/Caddy in front of the server if you already run one: certificate
## renewal is a solved problem there and is not one here.
@export var use_tls: bool = false

@export_file("*.crt", "*.pem") var tls_cert: String = ""
@export_file("*.key", "*.pem") var tls_key: String = ""

## Client-side: skip certificate verification.
##
## [b]Development only.[/b] It disables the guarantee that makes TLS worth
## having, so it is logged at WARN every time a connection uses it — an
## unverified connection that nobody notices is how a debug flag reaches
## production.
@export var tls_trust_all: bool = false

## Client-side: verify against this CA bundle instead of the system store.
##
## For self-signed certificates on a LAN, which is the honest alternative to
## [member tls_trust_all].
@export_file("*.crt", "*.pem") var tls_ca_bundle: String = ""

@export_group("WebSocket")

## Path the server accepts and clients request.
##
## Distinct from [code]/[/code] so a reverse proxy can route game traffic and the
## website on one hostname — which is what makes same-origin content delivery
## possible, and same-origin is what makes CORS stop being a problem.
@export var path: String = "/game"

## Subprotocols offered in the handshake.
##
## Doubles as a cheap version gate: a client built against an incompatible wire
## format offers a different subprotocol and is refused at the handshake instead
## of desynchronising later.
@export var handshake_protocols: PackedStringArray = PackedStringArray(["dot.v1"])

## Seconds to complete the WebSocket handshake.
@export_range(0.5, 60.0, 0.5) var handshake_timeout_sec: float = 5.0

@export_group("Buffers")

## Per-peer inbound buffer, as a power-of-two exponent (16 = 64 KiB).
##
## Must exceed the largest single packet. dot-cloud's in-band content chunks are
## the largest thing on the wire, so this is sized for them; a too-small buffer
## shows up as a peer disconnecting mid-download with no other explanation.
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


## Turns a user-typed address into the URL [method WebSocketMultiplayerPeer.create_client]
## needs.
##
## Fills in the scheme, port and path from this transport's settings when the
## input omits them, so a player can type [code]play.example.com[/code] and get
## [code]wss://play.example.com:443/game[/code].
##
## An explicit port always wins; after that the [i]scheme[/i] chooses, and only then
## this transport's own defaults. See the note beside the port below: taking the
## default from [member use_tls] made every [code]wss://[/code] address with no port
## dial 27015.
##
## When running in a browser on an HTTPS page, an explicit [code]ws://[/code] is
## upgraded to [code]wss://[/code]: the browser would refuse it anyway, and
## failing at connect time with a clear log line beats a silent block.
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

	# [b]The port follows the SCHEME, not this transport's own `use_tls`.[/b]
	# `use_tls` says whether the socket *this node opens as a server* terminates TLS;
	# it says nothing about an address a client was handed. So `wss://host/game` — the
	# documented way to reach a server behind a TLS terminator, and the only way a
	# browser on an HTTPS page can reach one at all — took the `use_tls == false`
	# branch and silently dialled 27015. Nothing said so: the connection simply failed
	# with "could not reach the server", which reads as the server being down.
	if int(parts["port"]) <= 0:
		if port > 0:
			parts["port"] = port
		elif str(parts["scheme"]) == "wss":
			parts["port"] = 443
		else:
			parts["port"] = _default_port()

	if str(parts["path"]) == "":
		parts["path"] = path

	# [method DotWeb.is_https_page], not [method DotWeb.is_secure_context]. A browser
	# treats http://localhost and http://127.0.0.1 as trustworthy origins, so
	# `isSecureContext` is true on a plain HTTP page served from either — and mixed-content
	# blocking, which is the rule that actually decides this, exempts exactly those
	# origins. Asking the wrong one upgraded every development page's ws:// to wss:// and
	# failed against a server with no certificate, which is every server anybody tests
	# against locally. It is the reason nothing in this family had ever loaded in a
	# browser.
	if str(parts["scheme"]) == "ws" and DotWeb.is_https_page():
		DotLog.warn(
			CHANNEL,
			"upgrading ws:// to wss:// — a page served over HTTPS may not open an "
			+ "insecure socket",
			{"host": str(parts["host"])}
		)
		parts["scheme"] = "wss"

	return DotTransport.format_address(parts)


## The port to use when neither the caller nor the address named one and the scheme
## does not imply one.
##
## [member use_tls] is this node's own listener setting, so this is the right default
## for opening a server and the wrong one for dialling somebody else's — which is why
## [method build_url] asks the scheme first.
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
