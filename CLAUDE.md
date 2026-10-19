# dot-core

Shared foundation for the dot-* family: logging, platform capability detection, filesystem handling, configurable node references, layered configuration, frame-budgeted background work, hashing, reproducible randomness, HTTP, the multiplayer transports, and addon API levels. Every other addon depends on it, and it depends on nothing.

**The distributable is `addons/dot_core/`.** `project.godot` and `examples/` exist so the addon can be opened and validated on its own.

The family-wide conventions in [game-dev/CLAUDE.md](../../CLAUDE.md#family-wide-conventions) (no autoloads, `DotNodeRef`, `DotResult`, capabilities not platforms, `Dot` prefix, layered config, `DotLog` levels, `print`/`push_error`, `describe()`) are implemented here; changing one is a breaking change for every repository. The reasoning for what is specific to dot-core is in [docs/](docs/README.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/engine-traps.md](docs/engine-traps.md) | comparing a `Variant`, touching `DotWeb`, emitting from a thread, `DotLog`'s engine mirror |
| [docs/transports.md](docs/transports.md) | anything in `net/`, a platform constraint, `DotHttp` |
| [docs/addon-api.md](docs/addon-api.md) | adding to or removing from any addon's API; `requires.json`; `requires.floor.json` for a game that guards a newer level |
| [docs/randomness.md](docs/randomness.md) | anything in `random/`, or writing a seeded draw anywhere |
| [docs/camera.md](docs/camera.md) | anything in `camera/`, or any camera that is not a player's own eyes |
| [docs/loading.md](docs/loading.md) | anything in `loading/`, a loading screen, or a game shown before its world is in |

## Layout

| Path | What |
| --- | --- |
| `core/dot_content_index.gd`, `dot_content_entry.gd` | what mounted packs provide (`entries(kind)`), tagged solo or online; registered as `dot_content_index`; dot-cloud fills it, catalogues read it; `examples/content_index_selftest` |
| `core/dot_error.gd`, `dot_result.gd` | failure codes (`CODE_*` is the contract); ok/value/error, where reading `.value` on a failure errors |
| `core/dot_platform.gd`, `dot_web.gd` | cached capability detection; JavaScriptBridge access, safe on every platform |
| `core/dot_paths.gd` | path sanitisation (traversal refusal), atomic writes |
| `core/dot_log.gd`, `dot_log_bus.gd`, `dot_log_sink.gd` | levelled, channelled logging; its signal carrier; the rotating file sink (a Node) |
| `core/dot_registry.gd`, `dot_registry_bus.gd` | name to instance, the autoload replacement; its signal carrier |
| `core/dot_node_ref.gd` | configurable "which node". Read it first |
| `core/dot_config.gd` | layered configuration base |
| `core/dot_job.gd`, `dot_scheduler.gd`, `dot_hash_job.gd` | sliceable work, frame budget and worker pool, chunked file hashing |
| `core/dot_hash.gd`, `dot_rate_limiter.gd`, `dot_semver.gd`, `dot_value.gd` | SHA-256/HMAC/constant-time compare/base64url; token bucket; versions that do not sort 0.10 below 0.9; total comparisons |
| `core/dot_collision_audit.gd` | `DotCollisionAudit.audit(root)`: visible meshes, CSG, GridMaps and MultiMeshes with no covering collision; opt out with metadata or group `dot_no_collision`, inherited; `examples/collision_audit_selftest` |
| `core/dot_addon_api.gd`, `dot_core_api.gd`, `tools/dot_requires.gd` | API levels and the refusal sentence; dot-core's own level; derives or audits a game's `requires.json`, lowered by its `requires.floor.json` |
| `tools/dot_parse_all.gd` | the parse pass in ONE process (no `class_name`): reads a list of scripts, loads each fresh, prints `PARSE> path` on stderr before it and `PARSE_FAIL path` after a failure, `PARSED n FAILED m` on stdout, exits 1 on any failure. About 10x faster than `--check-only` per file (66 scripts: 40 s against 4 s), same verdicts; dot-ci's `check.sh` uses it when present. `examples/parse_all_selftest` writes bad scripts to `user://` at run time, so no broken `.gd` is tracked |
| `net/` | `dot_transport*.gd` (base with address parsing incl. bracketed IPv6, websocket, enet, auto, dual), `dot_dual_peer.gd`, `dot_udp_demux.gd`, `dot_tcp_screen.gd` (closes a TLS hello and a plain HTTP request (no Upgrade: websocket) at the plain WebSocket port, relays the rest), `dot_metered_peer.gd`, `dot_http.gd` |
| `random/` | `dot_random_stream.gd`, `_table.gd`, `_schedule.gd`, `_config.gd`, `_manager.gd` (the node a game holds; the only thing that knows the seed) |
| `camera/` | `dot_camera_probe.gd` (a swept sphere from a pivot, eased in ahead of an obstacle and out behind it), `dot_camera_boom.gd` (the `SpringArm3D` replacement built on it), `dot_camera_fade.gd` (fades characters between the camera and its focus, hides one at the camera; `bodies_fn` for characters with no collider), `dot_camera_check.gd` (flies a camera along a scripted path, armed), `dot_camera_tool.gd` (the base of every game's `tools/render_cameras.gd`), `dot_render_warmup.gd` (draws a scene's materials once out of sight so shaders compile under a loading screen) |
| `loading/` | `dot_load_gate.gd` (`DotLoadGate`: `hold`/`release`/`require` reasons, `freeze` nodes while held then settle them under the cover with input off (`settle_frames`, `freeze_input`, `is_settling`), `warm_up` items, a timeout that opens with a warning; finds a host by `dot_load_gate_host` metadata, else covers itself and runs `DotRenderWarmup`; registered as `dot_load_gate`), `dot_loading_cover.gd` (the stock cover) |
| `examples/` | `capability_report`, `http_selftest`, `value_selftest`, `addon_api_selftest`, `dual_transport_selftest`, `randomness_selftest`, `camera_selftest`, `scheduler_selftest`, `collision_audit_selftest`, `content_index_selftest`, `load_gate_selftest`, `parse_all_selftest` |

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), which dot-ci runs on every push. Then every scene in `examples/`; each selftest exits non-zero on failure. `scheduler_selftest` puts real threads into one job, cancels under a worker and closes a hash job's file under it. `dual_transport_selftest` runs real WebSocket and ENet clients, a metered client, a query on the shared port, the server's bandwidth, the packet throttle's settings, peer timeouts, a shutdown, and a TLS ClientHello closed by the TCP screen (armed: the same hello with the screen off). **Run `capability_report` on each export target**: it reports whether that build has threads, UDP and a storage quota. A dot-core change touches every consumer: re-run `--import` in projects that link it after adding a `class_name`.

## Rules that bite

- Compare a `Variant` whose type you do not control with `DotValue.same`/`differs`, never `==`/`!=`: a mismatched-type comparison is a runtime error that leaves the condition undefined. [traps](docs/engine-traps.md#-and--are-not-total-dotvalue)
- A `JavaScriptObject` forwards every member access: read `.prop`, call `.method(…)`, never `.get(…)`/`.call(…)`. [traps](docs/engine-traps.md#a-javascriptobject-is-not-an-object)
- A signal emitted from thread-capable code is deferred to the main thread (`DotJob._emit_on_main_thread()`). [traps](docs/engine-traps.md#signals-from-worker-threads-must-be-deferred)
- One thread inside a `DotJob` at a time: steps and settles hold its lock, `cancel()` never tears down another thread's step, a job is submitted once. Never call `FileAccess.eof_reached()` on a file that may be closed: it is a null dereference, not an error. [traps](docs/engine-traps.md#one-job-one-thread-at-a-time-and-eof_reached-is-not-null-checked)
- Ask `DotPlatform` before calling something that is itself the error (`has_unique_id()` before `unique_id()`). [traps](docs/engine-traps.md#some-calls-are-the-damage)
- `DotLog` mirrors only ERROR and above into the engine; never `push_warning` a runtime condition. [traps](docs/engine-traps.md#push_warning-staples-a-backtrace-on)
- Never name `ENetMultiplayerPeer`, `WebRTCMultiplayerPeer` or another template-optional class: reach it through `ClassDB.instantiate` and `Object.call`. [transports](docs/transports.md#where-each-constraint-lives)
- Behind `DotUdpDemux` ENet sees 127.0.0.1: use `DotDualPeer.get_peer_address` for bans, limits and logs. [transports](docs/transports.md#dottransportdual)
- Behind `DotTcpScreen` WebSocket sees 127.0.0.1 too, and its sends are written inside `put_packet`, so a WebSocket send queues one deferred screen flush per frame or every packet leaves a frame late. Auto screens only a non-loopback bind: the relay costs ~12 us per busy link per frame. [transports](docs/transports.md#dottransportdual)
- A `DotDualPeer` send to an ENet peer checks it still has channels: ENet emits `peer_disconnected` before dropping a peer, and a second leaver has none. [transports](docs/transports.md#dottransportdual)
- A `DotDualPeer` send to a WebSocket peer checks it is `STATE_OPEN`, broadcasts included: the engine keeps closed peers in its table (and emits `peer_disconnected` before erasing) and its broadcast does not ask. [transports](docs/transports.md#dottransportdual)
- ENet's incoming bandwidth is 0 and its peer timeouts are the transport's (30 s), not ENet's. [transports](docs/transports.md#dottransportdual)
- ENet's packet throttle deceleration is 0 on every peer: stock, a reliable burst over one long frame drops a client's commands and snapshots at the sender. [transports](docs/transports.md#dottransportdual)
- A peer wrapper connects its inner peer's signals to methods, never self-capturing lambdas. [transports](docs/transports.md#dotmeteredpeer)
- Every write to `user://` calls `DotWeb.sync_filesystem()`.
- Add to an addon's API: bump its `LEVEL`. Remove or change: raise `OLDEST` to `LEVEL`. The api file has no `class_name`. [api](docs/addon-api.md#the-rule-for-every-addon)
- A game guarding an addon's newer level names it in `requires.floor.json`, or its pack still asks for the built level and an older host refuses it before the guard runs. [floors](docs/addon-api.md#requiresfloorjson-asking-less-of-an-addon-the-game-guards)
- A seeded draw is a pure function of (key, index); derive streams by name. Splitmix constants are signed decimals, `>>` needs `_unsigned_shift`, and `String.hash()` is not a stable seed. [randomness](docs/randomness.md)
- A camera that is not a player's own eyes goes through `DotCameraProbe` (or `DotCameraBoom`), never `SpringArm3D`; characters are faded by `DotCameraFade`, never collided with; a "never inside" check flies the same path with no probe and requires it to fail. [camera](docs/camera.md)
- A suite that adds a `DotLog` sink removes it before exit: a Callable left in DotLog's static list aborts the process at teardown (heap corruption after "0 failed"). [loading](docs/loading.md#things-that-look-wrong-and-are-not)
- `DotConfig` unknown keys warn, never fail; `sensitive_keys()` blocks environment and argv.
- Set `require_type` on a `DotNodeRef` a host configures by path: a type error at boot beats a null call mid-session.

## Things deliberately not here

- **WebRTC transport.** It ships as an optional GDExtension, so it lives in [dot-peer-to-peer](../dot-peer-to-peer), which reaches every WebRTC class through `ClassDB.instantiate` so a build without the extension still compiles. `DotPlatform.has_webrtc()` probes for it.
- **DTLS for ENet.** It is configured on `ENetConnection`, not the peer; WebSocket + TLS covers the encrypted case, and no bearer secret goes over ENet.
- **Anything beyond a rotating log file.** That is [dot-log](../dot-log), which registers one sink and owns everything downstream; `DotLogSink` stays here because a project whose only dependency is dot-core still needs a log file.
- **A unit-test framework.** The selftest scenes are the suites; GUT or gdUnit would still be an improvement and has no blockers.

## Open items

- dot-map, dot-vote, dot-2d, dot-team and dot-procedural-generation still draw from their own generators rather than `random/`. [randomness](docs/randomness.md#addons-that-hand-rolled-a-generator)
