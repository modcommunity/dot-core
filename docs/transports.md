# Platform constraints and the transports

## Where each constraint lives

| Constraint | Where it lives |
| --- | --- |
| Browsers have no UDP; `ENetMultiplayerPeer` is absent from the web template | `DotTransportENet` reaches ENet via `ClassDB.instantiate` + `Object.call`, never by name: a script mentioning the identifier fails to compile on web |
| Browsers have no `HTTPClient`, only `HTTPRequest` | `DotHttp` uses `HTTPRequest` unconditionally |
| `user://` on web is an IndexedDB mirror needing explicit flushes | every write path calls `DotWeb.sync_filesystem()` |
| Web builds may have no threads | `DotScheduler` slices on the main thread inside a frame budget |
| A mounted PCK can never be unmounted, on any platform | `DotPlatform.can_unmount_packs()` returns false; see dot-cloud |
| A browser tab cannot listen for connections | `DotTransport.create_server()` refuses early with an explanatory error |
| One listening socket speaks one protocol | `DotTransportDual` listens twice behind one peer |
| `OS.get_unique_id()` pushes an engine error on web and iOS before returning "" | `DotPlatform.has_unique_id()` / `unique_id()`: ask first |

## `DotTransportDual`

A server that serves browsers (WebSocket, TCP) and native clients (ENet, UDP) listens on both. `DotTransportDual` does that behind one `MultiplayerPeer` (`DotDualPeer`, a `MultiplayerPeerExtension`): it polls both backends, merges their peers into one id space and routes each send by the target's backend, so `SceneMultiplayer`, dot-net and the games see one peer. It is dot-server's default (`transport_mode: dual`). Before it, every client spoke WebSocket and desktop players had TCP's head-of-line blocking on every snapshot.

- **Peer ids can collide.** ENet clients pick their own id and WebSocket clients are given one, both random. A newcomer whose id the other backend already holds is disconnected, not renumbered (a renumbered client would believe its own id is one the server never uses); the reconnect draws a fresh id.
- **ENet cannot share its socket with A2S/DQP** (Godot binds no receive hook on `ENetConnection`), and the game's UDP port answers queries by default. So `DotUdpDemux` owns the public UDP port: datagrams a registered handler claims (A2S `FF FF FF FF`, DQP `DQP1`) go to it; everything else is relayed to an ENet host on loopback through **one relay socket per remote client** (one shared socket would make every client one ENet peer). A relay is opened only for an ENet connect header (peer id 0xFFF), and capped, so a spoofed flood cannot open a socket per source. A compressed connect whose first four bytes happen to be `FF FF FF FF` is lost to the query handler and ENet retransmits it.
- **The relay hides the client's address from ENet**, which sees 127.0.0.1 for everybody. `DotDualPeer.get_peer_address` maps it back; bans, rate limits and logs must use that, never ENet's `get_remote_address`.
- **`_create_server` passes 0 as ENet's incoming bandwidth.** The engine's `ENetMultiplayerPeer.create_server` hands its channel argument to ENet as the host's incoming bandwidth, so passing four channels told every native client the server takes 6 B/s, and the client throttled its unreliable packets (its commands) for up to twenty seconds.
- **ENet's own peer timeouts are raised** (`DotTransportENet.peer_timeout_limit / _min_ms / _max_ms`, 1024 / 10 s / 30 s, set on every peer as it connects). ENet's defaults drop a peer once one reliable command has been resent five times over five seconds, which at 20% loss each way dropped a player still sending every tick. dot-server's `client_timeout_sec` decides when a silent client is gone.
- **Shutdown says goodbye through the demux.** Behind the demux an ENet send only reaches the loopback relay until `pump_out()`, so closing the host and then the demux in one call sent nothing. `_say_goodbye_through_demux` disconnects each ENet peer gracefully, services the host and pumps the demux before closing.
- **A leaving ENet peer is asked before it is sent to.** A client's disconnect frees its peer's channels inside ENet the moment the datagram is read, but ENetMultiplayerPeer keeps the peer in its table until the event is dispatched, and emits `peer_disconnected` before removing it. So when two clients leave in one poll, everything the first one's handler sends to the second ("player left", chat presence) logged "Unable to send packet on channel N, max channels: 0", and an all-but-one send logged "Parameter "peer" is null" for the first. `_enet_sendable` (channels > 0) drops a targeted send as ENet drops one to a disconnecting peer, and `_send_enet_except` sends to each live peer itself while either kind is in the table. `dual_transport_selftest` "leaving in one poll" watches the engine log for both lines.
- **ENet failing in any way** (no ENet in the build, a busy port) degrades to WebSocket only with a WARN, never a failed start.
- **ENet is cleartext**: dot-server's client link never sends a bearer secret over it ([dot-server's transports.md](../../dot-server/docs/transports.md)). There is no DTLS here: it is configured on `ENetConnection`, not the peer, and WebSocket + TLS covers the encrypted case.
- `DotTransportAuto.require_web_clients` still defaults to `true` for projects that use Auto on a server.

## `DotMeteredPeer`

Wraps any peer and counts bytes and packets per channel (dot-server's client link uses it; dot-menu's net_stat draws it).

- A WebSocket peer reports every packet on channel 0, so a browser cannot split arrivals by channel.
- **A wrapper connects its inner peer's signals to methods, never to lambdas capturing itself**, or the two peers hold each other and neither socket is freed.

## `DotHttp`

`examples/http_selftest.tscn` binds a loopback port and speaks enough HTTP/1.1 to answer the four responses that decide whether a download is correct: a 206 continuing a partial, a 200 from a host that ignored `Range`, a 416, and a 500 part-way through a resume. **A server in the test is deliberate**: everything interesting about `DotHttp.download_to_file` is how it reacts to what comes back, and mocking `HTTPRequest` would test the mock. A failed `fetch()` in a browser is almost always CORS; dot-cloud's docs have the headers a content host needs.
