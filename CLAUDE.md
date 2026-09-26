# dot-core

Shared foundation for the `dot-*` Godot asset family. Everything the other three
addons need in common: logging, platform capability detection, filesystem
handling, configurable node references, layered configuration, frame-budgeted
background work, hashing, reproducible randomness, HTTP, and the multiplayer
transport abstraction.

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

**Sometimes the capability question has to come first because the call itself is
the damage.** `OS.get_unique_id()` does not fail quietly on web or iOS: it pushes
`OS::get_unique_id() is not available on the Web platform` and *then* returns the
empty string. Five callers across dot-auth, dot-server and dot-user checked the
result for emptiness and fell back correctly — after each had printed a red engine
error, on the page a player has open and in the log a bug report is pasted from,
naming a function nobody called on purpose. `DotPlatform.has_unique_id()` and
`DotPlatform.unique_id()` are the honest form: ask whether the capability is there
before reaching for it, rather than reaching for it and reading the wreckage.
Found by loading the browser client, which is the only place it was visible.

### `==` and `!=` are not total. Use `DotValue` where a type is not yours.

GDScript's comparison operators between two **mismatched Variant types** are a runtime
error, not `false` and `true`. The expression is abandoned, an error is pushed, and the
calling function carries on with an undefined condition — so the caller sees a plausible
answer and the only trace is a line in a log nobody is reading.

This family has now paid for it twice. `DotNpcAiBlackboard.has()` was the textbook
sentinel comparison — `get_value(key, now, MISSING) != MISSING` — and answered false for
every value that was not a `StringName`, because comparing a `Vector3` with one is an
error rather than a difference. dot-settings then hit the identical thing comparing a
coerced value with the raw one it came from, and **its suite reported "0 failed" and
exited 0** while eight checks never ran.

`DotValue.same` / `differs` / `is_blank` / `same_dictionary` answer the question that was
actually being asked. Two foldings are deliberate and documented at the call site: int
against float, and `StringName` against `String` — a document that made a round trip
through JSON otherwise reports a change on every single load.

Use them **anywhere either side is a `Variant` whose type you do not control**: a config
file, a wire message, a saved document, a sentinel. Ordinary comparisons between two
values of a declared type stay as they are; wrapping those would be noise.

### A `JavaScriptObject` is not an `Object`. Use `.name` and `.name(args)`.

Everything `DotWeb.get_global` hands back is a `JavaScriptObject`, and it forwards **every** member access to the JavaScript object behind it. So `obj.get("hidden")` does not read a property: it invokes a method called `get` on `document`, which does not have one, and the browser answers `TypeError: obj[method] is not a function`. `obj.call("addEventListener", …)` fails the same way, for a method called `call`. Both are the spelling every other Godot `Object` takes, both parse, both are silent off-web, and neither reaches any headless check.

Read properties with `.hidden`. Call methods with `.addEventListener(…)`. The bridge singleton itself is an ordinary `Object`, so `bridge().call("get_interface", name)` inside this file is correct and is not the same thing.

**This tree has paid for it twice** — dot-auth's web handoff first, then `DotWeb.watch_visibility`, which attached no listener at all and made the browser-tab keepalive a no-op that passed 237 checks. The rule lives here now rather than in one consumer's margin.

### Signals from worker threads must be deferred.

`DotJob._emit_on_main_thread()` exists because GDScript resumes an awaiting
coroutine *synchronously inside `Signal.emit`*, on whatever thread called it. A
job finishing on a scheduler worker would resume `await job.finished` on that
worker, and the next ordinary-looking line of caller code — appending to a label,
adding a node, mounting a pack — touches the scene tree off-thread.

**This was a real bug found by running `examples/capability_report.tscn`, not by
reading the code.** Any new signal emitted from thread-capable code needs the
same treatment.

## Reproducible randomness

`random/` was `dot-randomness`, a repository of its own, until it was folded in here. It is in dot-core rather than beside it because **it could never have been optional**: it already depended on `DotConfig`, `DotError`, `DotLog`, `DotRegistry` and `DotResult`, and while it sat behind an extra vendored addon nobody installed it. Six addons hand-rolled a generator instead — dot-spawn, dot-combat, dot-team, dot-map, dot-vote and dot-2d — and two of those hand-rolled the *same algorithm this file implements*, worse. Determinism has to arrive with dot-core or it does not arrive.

**The one idea: a draw is a pure function of (key, index), not a position in a moving cursor.** `at(index)` touches nothing, answers the same on every machine, and works for an index nobody has reached. `stream(name)` derives a child by hashing the name in, so two subsystems never disturb each other and the order they were created in stops mattering. Three failures this prevents have all happened in this tree: two peers drawing in a different order diverge for the rest of the session; inserting one roll changes every replay recorded before it; and a stream a receiving peer cannot mirror, because it must *adopt* an index rather than allocate one — which is what `adopt()` is named for.

Three things about the splitmix64 mixer are load-bearing and **all three fail silently**:

- **The constants are written as signed decimals.** All three are above 2^63 and GDScript's `int` is signed, so the hex spelling either fails to parse or quietly becomes a float — and a mixer that is a float is not a mixer. dot-combat hit exactly this and cleared the top bit of each constant to make them fit, leaving something that mixed but was no longer the algorithm it named.
- **`>>` is arithmetic.** Shifting a negative value keeps the sign bits, so the top of the output is a run of ones rather than entropy. `_unsigned_shift` masks after the shift. Half of every mixer's output has the high bit set, so this is not an edge case — it is half of them.
- **Take the bits you meant to take.** `DotSpread.unit()` took 23 where it meant 24 and so never returned a value above 0.5: every shotgun pattern was a half-moon, and a maximum-magnitude assertion passed throughout. The suites count quadrants and buckets for that reason and never assert one particular number.

`_hash_name` is FNV-1a rather than `String.hash()`, which is 32-bit and is not promised to be stable across engine versions — a seed that means a different world after an engine upgrade was never shareable. `dot-spawn` folded its key in with `hash()` for the same reason it should not have, and now derives a named stream instead.

**`mix4` and `unit_from` are public on purpose.** A subsystem whose draw is a pure function of several integers has nowhere to keep a stream object and will not allocate one per pellet. Given no shared entry point it writes its own mixer, which is how the family got two. The seed is public, deliberately: a client can compute every number the server will, so anything that must be secret from a player belongs behind a value they do not have.

## Which addon API a build has: `DotAddonApi`

**A delivered pack's scripts compile against the HOST's addons**, so a pack written against a newer addon than the client shell or server has does not fail with a sentence: it fails to parse, mid-load, with an identifier that "is not declared in the current scope". `DotAddonApi` turns that into *"This game needs dot-net API level 3 or newer; this server has level 2."*, asked before a single script in the pack is loaded (dot-cloud asks it between download and mount).

**The number is an API level, not the release version, and that choice is the point.** The tag's semver is honest only in a release: dot-ci stamps it into `plugin.cfg`, but a developer checkout is a symlink whose `plugin.cfg` says 0.1.0 whatever it holds, `plugin.cfg` is not a resource so an exported build does not carry it, and a tag moves for a bug fix that changes no API — "needs 0.4.1" would refuse a 0.4.0 host that runs the pack perfectly. A level committed in the addon's own source is the same number in all three places, because it is code.

**The rule, for every addon:** `addons/<addon>/<addon>_api.gd` holds `const LEVEL` and `const OLDEST` (dot-core's is `dot_core_api.gd`, no `class_name`, so sixty addons do not add sixty globals). Bump `LEVEL` when you **add** anything a game could call. Raise `OLDEST` to the new `LEVEL` when you **remove or change** something a game could have called, because every pack built before that no longer compiles here. An addon with no api file is at level 1 — the level everything was at when the scheme began (2026-09-26) — so adopting it touched no addon that had nothing to say.

**A pack says what it needs in `requires.json` at its root**, `{"format": 1, "addons": {"dot_net": 3}}`, and nobody keeps it by hand: `addons/dot_core/tools/dot_requires.gd` derives it from the game's own files (every global class declared under `res://addons/<x>/` that a script, scene or resource names, and every literal `res://addons/<x>/` path), at the levels the building checkout has — "built against", which is conservative on purpose. dot-ci's `package.sh --pack` writes it into the pack; a game that commits its own keeps control of it and the release audits it instead (`--check`), failing on an addon used and not declared or a level above what the build has.

`overrides` exists because a client and a server in one process share one set of addon files, so "an older client" can only ever be a claim; `addon_api_selftest` (36 checks) asserts the sentences, not just `CODE_VERSION`.

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
godot --headless --path . res://examples/http_selftest.tscn   # 36 checks, exits non-zero
godot --headless --path . res://examples/value_selftest.tscn  # 27 checks, exits non-zero
godot --headless --path . res://examples/addon_api_selftest.tscn  # 36 checks, exits non-zero
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
- **`print` and `push_error` are not logging.** `DotLog` is for anything at runtime an
  operator might read: it has a level, a channel and fields, it is greppable, and it
  reaches the log file and whatever the records are shipped to. `print` is a program's
  *output* — a CLI tool's stdout, a console echoing the line the operator typed — which
  is not a log and must not be levelled or filtered away. `push_error` is for a
  **programmer** error that wants the Errors dock and a stack: an abstract method not
  overridden, a null argument, a static class somebody instantiated. The test is who is
  expected to act — an operator, or the person editing the file. `push_warning` for a
  runtime condition is always wrong: see below for what the engine staples to it.
- **`DotLog` mirrors only ERROR and above into the engine.** `push_warning` /
  `push_error` are how a record reaches the editor's Errors dock and a crash
  report, and in a debug build the engine appends an `at:` line and a full
  GDScript backtrace to each one — **with no way to suppress that per call**
  (`Engine.print_error_messages = false` is the only switch and it silences real
  runtime errors too). At WARN that turned every expected, recoverable warning
  into eight lines of stderr that read like a crash, duplicating a `WRN` line
  this class had already printed. `mirror_min_level` is that threshold; set it to
  `Level.WARN` while hunting one specific warning's origin.
- **Anything beyond a rotating file is [dot-log](../dot-log)**, which registers
  one sink and owns everything downstream of it: an in-memory ring, syslog, a SQL
  table, and batched HTTP to the log services, with the gating, redaction and
  back pressure in front of all of them. `DotLogSink` stays here because a
  project whose only dependency is dot-core still needs a log file.
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
    dot_value.gd         Comparisons that are total. Read the next section.
    dot_addon_api.gd     API levels, requires.json, and the sentence when a pack needs more.
  dot_core_api.gd        dot-core's own API level. Every addon may have one.
  tools/
    dot_requires.gd      Derives or audits a game's requires.json. dot-ci runs it.
  net/
    dot_transport.gd           Base + address parsing (incl. bracketed IPv6).
    dot_transport_websocket.gd Serves browser + native from one listener.
    dot_transport_enet.gd      Lower overhead, no browsers. Dynamic ENet access.
    dot_transport_auto.gd      Picks one and logs why.
    dot_http.gd                HTTPRequest wrapper: retries, resume, pooling.
  random/
    dot_random_stream.gd   A key and an index. Splits by name, mirrors by adopt.
    dot_random_table.gd    Weighted ids, three policies, pity honest about its rate.
    dot_random_schedule.gd Random events in ticks, from a pure function of the tick.
    dot_random_config.gd   The seed, the scope, whether to announce it. A DotConfig.
    dot_random_manager.gd  The node a game holds. The only thing that knows the seed.
```

## Things deliberately not here

- **WebRTC transport.** `DotPlatform.has_webrtc()` probes for it, but the module
  ships as an optional GDExtension rather than in standard templates, so a
  transport implementation would be untestable in a default install. **dot-p2p is
  where it went**, for exactly the reason this entry gave: it reaches every WebRTC
  class through `ClassDB.instantiate`, never by name, so a build without the
  extension still compiles — the same rule `DotTransportENet` follows for the web
  template.
- **DTLS for ENet.** Configured on `ENetConnection` rather than the peer, and the
  dynamic-access indirection makes it fiddly. WebSocket + TLS covers the
  encrypted case today.
- **A unit test suite.** `capability_report` and `http_selftest` are the smoke
  tests, and the second is a real pass/fail suite. GUT or gdUnit would still be
  an improvement and has no blockers.
