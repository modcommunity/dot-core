This is the **core** asset for TMC's **Dot** collection. This asset provides the foundation for all other `dot-*` assets and ensures they work together seamlessly.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## The Foundation of the `dot-*` Asset Family
Shared foundation for the `dot-*` Godot 4 asset family — the common layer under
[dot-server](../dot-server), [dot-auth](../dot-auth) and
[dot-cloud](../dot-cloud).

Targets desktop (Windows, macOS, Linux), mobile (Android, iOS) and the web from
one codebase, and encodes the browser's limitations rather than pretending they
do not exist.

## Install

Copy `addons/dot_core/` into your project and enable **dot-core** in
*Project → Project Settings → Plugins*. The plugin only registers inspector
types; every class is available via `class_name` whether it is enabled or not.

Requires Godot 4.4 or newer.

## What is in it

| | |
| --- | --- |
| **`DotResult` / `DotError`** | The return type of everything fallible. Stable `CODE_*` values callers branch on; reading `.value` on a failure errors instead of handing back a default. |
| **`DotPlatform`** | Cached capability detection — threads, UDP, listening, pack mounting, storage family. Ask about capabilities, not platform names. |
| **`DotNodeRef`** | An inspector-editable description of *which node*: relative, absolute, group, registry, ancestor/descendant by type, or create-if-missing. Replaces hardcoded scene paths. |
| **`DotConfig`** | Layered configuration: exported defaults < file < environment < command line, with reflective key discovery and secret-key protection. |
| **`DotScheduler` / `DotJob`** | Long work in slices. Worker threads where available, a per-frame time budget where not. |
| **`DotTransport`** | Swappable multiplayer transport. WebSocket serves browser and native clients from one listener; ENet is lighter but browser-incompatible. `DotTransportAuto` picks and logs why. |
| **`DotHttp`** | `HTTPRequest`-based client with retries, jittered backoff, `Retry-After`, range-resumed downloads and connection pooling. Works in the browser sandbox. |
| **`DotLog` / `DotLogSink`** | Levelled, channelled logging with structured fields, rotating files and UDP forwarding. |
| **`DotPaths`** | Path sanitisation that *refuses* traversal rather than cleaning it, atomic writes, and web filesystem flushing. |
| **`DotHash`** | SHA-256, HMAC, constant-time comparison, base64url, CSPRNG tokens. |

## Try it

```bash
godot --headless --path . res://examples/capability_report.tscn
```

Prints what the build can do and self-tests the pieces that need no network. Run
it on every target you ship to — it is the quickest way to discover that your web
export has no threads or that a device reports no storage quota, both of which
change how dot-cloud behaves.

## Design notes

**No autoloads.** An addon that ships one reserves a global name, fixes the
initialisation order, and cannot be instantiated twice. Use `DotRegistry` for
name-based lookup and place `Node`s yourself.

**Nothing hardcodes a scene path.** Anything that needs a host node exports a
`DotNodeRef`.

**Browser constraints are load-bearing, not edge cases.** No UDP, no
`HTTPClient`, no threads by default, an IndexedDB filesystem needing explicit
flushes, and no way to unmount a resource pack. See [CLAUDE.md](CLAUDE.md) for
where each one is handled.

## Licence

MIT — see [LICENSE](LICENSE).
