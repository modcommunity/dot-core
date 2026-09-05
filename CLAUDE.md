# dot-core

Shared foundation for the `dot-*` Godot asset family. Everything the other three
addons need in common: logging, platform capability detection, filesystem
handling, configurable node references, layered configuration, frame-budgeted
background work, hashing, HTTP, and the multiplayer transport abstraction.

**The distributable is `addons/dot_core/`.** Everything outside it — `project.godot`,
`examples/` — exists so the addon can be opened and validated on its own and is
not copied into consuming projects.

## Non-negotiables

These are the decisions the rest of the family depends on. Changing one is a
breaking change for all four repos.

### No autoloads. Ever.

An addon that ships an autoload reserves a global identifier in every project
that installs it, forces its own initialisation order, and cannot be
instantiated twice — which rules out running a listen server and a client in one
process, and running two server instances in one editor session. Both are things
dot-server has to do.

Instead: static utility classes (`DotLog`, `DotPaths`, `DotHash`), `Resource`
configuration (`DotConfig`, `DotTransport`), plain `Node`s the host places
(`DotScheduler`, `DotLogSink`, `DotHttp`), and `DotRegistry` for name-based
lookup.

Static classes cannot declare signals, which is why `DotLogBus` and
`DotRegistryBus` exist as one-signal objects handed out by `DotLog.signals()`
and `DotRegistry.signals()`.

### Never hardcode a scene path. Use `DotNodeRef`.

Any component that needs to attach to something in the host project exports a
`DotNodeRef` rather than a `NodePath`. It can resolve relative, absolute, self,
parent, group membership, registry lookup, nearest ancestor of a type, nearest
descendant of a type, or the current scene root — and can create the node if it
is missing. The host chooses per instance, in the inspector.

```gdscript
@export var players_root: DotNodeRef

func _ready() -> void:
    var res := players_root.resolve(self)
    if not res.ok:
        DotLog.result("game", "players root", res)
        return
    _players = res.value
```

Set `require_type` on refs a host configures by path. "MultiplayerSpawner
expected, got Sprite2D" at boot beats a null method call mid-session.

### Fallible operations return `DotResult`, not null.

GDScript has no exceptions and no tagged unions. Returning null loses the reason;
returning an `Array` pair loses type checking. `DotResult` costs one allocation
and makes a skipped `ok` check push an error instead of handing back a plausible
default. Reasons live in `DotError.CODE_*` — callers branch on the code, never on
the message.

`res.wrap("could not mount game 'dm_arena'")` adds context without discarding
the cause. `DotLog.result(channel, what, res)` collapses the log-and-return case.

### Ask about capabilities, not platforms.

`DotPlatform.has_threads()`, not `OS.get_name() == "Web"`. The mapping is not
one-to-one: a threads-enabled web template has threads, a single-threaded
desktop build does not.

### Signals from worker threads must be deferred.

`DotJob._emit_on_main_thread()` exists because GDScript resumes an awaiting
coroutine *synchronously inside `Signal.emit`*, on whatever thread called it. A
job finishing on a scheduler worker would resume `await job.finished` on that
worker, and the next ordinary-looking line of caller code — appending to a label,
adding a node, mounting a pack — touches the scene tree off-thread.

**This was a real bug found by running `examples/capability_report.tscn`, not by
reading the code.** Any new signal emitted from thread-capable code needs the
same treatment.

## Platform constraints this codebase encodes

| Constraint | Where it lives |
| --- | --- |
| Browsers have no UDP; `ENetMultiplayerPeer` is absent from the web template | `DotTransportENet` reaches ENet via `ClassDB.instantiate` + `Object.call`, never by name — a script *mentioning* the identifier fails to compile on web |
| Browsers have no `HTTPClient`, only `HTTPRequest` | `DotHttp` uses `HTTPRequest` unconditionally |
| `user://` on web is an IndexedDB mirror needing explicit flushes | every write path calls `DotWeb.sync_filesystem()` |
| Web builds may have no threads | `DotScheduler` slices on the main thread inside a frame budget when they do not |
| A mounted PCK can never be unmounted, on any platform | `DotPlatform.can_unmount_packs()` returns false; see dot-cloud |
| A browser tab cannot listen for connections | `DotTransport.create_server()` refuses early with an explanatory error |
| One listening socket speaks one protocol | see below |

### The transport decision

A server that must accept browser clients listens on WebSocket, and then *its
desktop clients also speak WebSocket*. There is no "ENet for desktop, WebSocket
for web" on one port. Running both means two listeners and two `MultiplayerAPI`
instances.

`DotTransportAuto.require_web_clients` defaults to `true` for that reason. With
it off, a desktop-only server picks ENet and every browser client silently fails
to connect — the most confusing failure in the family, because nothing looks
misconfigured from the server's side.

## Layered configuration

`DotConfig` subclasses declare `@export` properties; discovery is reflective, so
adding a setting needs no registration. Layers, later winning:

```
exported defaults  <  .tres / .json file  <  environment  <  command line
```

Key matching normalises `max_players` / `maxPlayers` / `max-players` to the same
property. Unknown keys are collected in `unknown_keys` and warned about, never
fatal — refusing to boot because a config mentions a setting from a newer version
is worse than ignoring it. `sensitive_keys()` blocks a property from being set
via environment or argv, because both are readable by other processes and end up
in `ps` output and bug reports.

## Validating changes

There is no CI here yet. Before handing work back, run both:

```bash
# 1. Every script parses, with class_name globals resolved.
#    The --import pass is required: without it every cross-file type
#    reference fails, which looks like dozens of unrelated errors.
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 2. It actually works at runtime.
godot --headless --path . res://examples/capability_report.tscn
godot --headless --path . res://examples/http_selftest.tscn   # 35 checks, exits non-zero
```

The second one matters. Parse-clean GDScript can still be wrong in ways only
execution shows — the thread-deferral bug above passed every parse check.
`capability_report` is also the thing to run on each export target: it reports
whether *that* build has threads, UDP, and a storage quota.

`http_selftest` binds a loopback port and speaks enough HTTP/1.1 to answer the
four responses that decide whether a download is correct: a 206 continuing a
partial, a 200 from a host that ignored `Range`, a 416, and a 500 part-way
through a resume. It is in-process and needs no network, so it belongs in the
same run as the parse pass.

**A server in the test file is deliberate.** Everything interesting about
`DotHttp.download_to_file` is how it reacts to what comes back, and mocking
`HTTPRequest` would only test the mock. The resume bug fixed on 2026-08-28 —
`HTTPRequest` has no append mode, so a ranged body written straight to the
destination replaced the partial with its own tail — produced a `DotResult` that
said `ok`, `resumed: true` and carried a plausible status. Only the bytes on
disk showed it. dot-auth's issuer speaks HTTP in GDScript for the same reason.

## Conventions

- Every class is prefixed `Dot`. `class_name` is global in Godot, and these four
  addons get installed side by side.
- Channel constants: each file that logs declares `const CHANNEL := "…"` and
  passes it, so channel levels can be tuned per subsystem
  (`DotLog.set_channel_level("net", DotLog.Level.DEBUG)`).
- `describe() -> Dictionary` on anything with runtime state, for `status`-style
  console commands and bug reports. `describe_lines() -> PackedStringArray` where
  the output is meant to be read by a human in a terminal.
- Comments explain *why*, and specifically why the obvious alternative is wrong.
  There are a lot of non-obvious platform trade-offs in here and the next reader
  will otherwise "simplify" one of them back into a bug.

## File map

```
addons/dot_core/
  core/
    dot_error.gd         Failure codes + messages. CODE_* is the contract.
    dot_result.gd        ok/value/error. Reading .value on a failure errors.
    dot_platform.gd      Capability detection, cached.
    dot_web.gd           JavaScriptBridge access, safe on every platform.
    dot_paths.gd         Path sanitisation (traversal refusal), atomic writes.
    dot_log.gd           Levelled, channelled logging + sinks.
    dot_log_bus.gd       Signal carrier for DotLog.
    dot_log_sink.gd      Rotating file sink + UDP forwarding. A Node.
    dot_registry.gd      Name -> instance. The autoload replacement.
    dot_registry_bus.gd  Signal carrier for DotRegistry.
    dot_node_ref.gd      Configurable "which node". Read this one first.
    dot_config.gd        Layered configuration base.
    dot_job.gd           Sliceable unit of work.
    dot_scheduler.gd     Frame budget + worker pool. A Node.
    dot_hash.gd          SHA-256, HMAC, constant-time compare, base64url.
    dot_hash_job.gd      Chunked file hashing as a DotJob.
    dot_rate_limiter.gd  Token bucket.
    dot_semver.gd        Version compare that does not sort 0.10 below 0.9.
  net/
    dot_transport.gd           Base + address parsing (incl. bracketed IPv6).
    dot_transport_websocket.gd Serves browser + native from one listener.
    dot_transport_enet.gd      Lower overhead, no browsers. Dynamic ENet access.
    dot_transport_auto.gd      Picks one and logs why.
    dot_http.gd                HTTPRequest wrapper: retries, resume, pooling.
```

## Things deliberately not here

- **WebRTC transport.** `DotPlatform.has_webrtc()` probes for it, but the module
  ships as an optional GDExtension rather than in standard templates, so a
  transport implementation would be untestable in a default install. Worth adding
  when peer-to-peer or unreliable-over-web is actually needed.
- **DTLS for ENet.** Configured on `ENetConnection` rather than the peer, and the
  dynamic-access indirection makes it fiddly. WebSocket + TLS covers the
  encrypted case today.
- **A unit test suite.** `capability_report` and `http_selftest` are the smoke
  tests, and the second is a real pass/fail suite. GUT or gdUnit would still be
  an improvement and has no blockers.
