# Engine traps dot-core exists to absorb

Each of these parses cleanly, is silent off the path that hits it, and has cost the family a real bug. The family-wide list is [gdscript-hazards.md](../../../docs/gdscript-hazards.md).

## `==` and `!=` are not total: `DotValue`

GDScript's comparison operators between two **mismatched Variant types** are a runtime error, not `false`/`true`. The expression is abandoned, an error is pushed, and the calling function carries on with an undefined condition, so the caller sees a plausible answer and the only trace is a log line.

- dot-npc-ai's blackboard `has()` was the textbook sentinel comparison (`get_value(key, now, MISSING) != MISSING`) and answered false for every value that was not a `StringName`.
- dot-settings hit the same thing comparing a coerced value with its raw source, and its suite reported "0 failed" and exited 0 while eight checks never ran.

`DotValue.same` / `differs` / `is_blank` / `same_dictionary` answer the question actually asked. Two foldings are deliberate: int against float, and `StringName` against `String` (a document that made a round trip through JSON would otherwise report a change on every load). Use them **anywhere either side is a `Variant` whose type you do not control**: a config file, a wire message, a saved document, a sentinel. Comparisons between two values of a declared type stay plain.

## A `JavaScriptObject` is not an `Object`

Everything `DotWeb.get_global` hands back is a `JavaScriptObject`, which forwards **every** member access to the JavaScript object behind it. `obj.get("hidden")` invokes a JavaScript method called `get` (`TypeError: obj[method] is not a function`), and `obj.call("addEventListener", …)` asks for a method called `call`. Both parse, both are silent off-web, and neither reaches a headless check.

Read properties with `.hidden`; call methods with `.addEventListener(…)`. The bridge singleton itself is an ordinary `Object`, so `bridge().call("get_interface", name)` inside `dot_web.gd` is correct. It has bitten dot-auth's web handoff, `DotWeb.watch_visibility` (no listener attached, the browser-tab keepalive a no-op that passed its suite) and dot-server-deploy's reload.

## Signals from worker threads must be deferred

GDScript resumes an awaiting coroutine **synchronously inside `Signal.emit`**, on whatever thread called it. A job finishing on a scheduler worker would resume `await job.finished` on that worker, and the next ordinary line of caller code (a label, a node, a pack mount) touches the scene tree off-thread. `DotJob._emit_on_main_thread()` exists for that; any new signal emitted from thread-capable code needs the same treatment. Found by running `examples/capability_report.tscn`, not by reading.

## One job, one thread at a time; and `eof_reached()` is not null-checked

`FileAccess.eof_reached()` on a closed file is a null `feof` inside the engine: signal 11, no error first. Every other `FileAccess` call on a closed file logs `File must be opened before use` and returns. A dedicated server died exactly so during a map change: a `DotHashJob` worker logged that error from `get_length` in `_setup`, then crashed in `eof_reached` in `_step`, because a second thread had been inside the same job and closed its file. The `propagate_notification()` error printed beside it is the crash handler sending `NOTIFICATION_CRASH` from the crashing worker, not a cause. Running two threads in one job reproduces the pair exactly; so does `cancel()` from the main thread landing between a worker taking a PENDING job and opening its file (which settled and closed it on the main thread).

So: `DotJob` holds a per-job `Mutex` for every step and every settle, and `_teardown` runs under it, so it never runs while another thread is inside a step; `cancel()` only `try_lock`s and otherwise leaves the flag for the stepping thread; `DotScheduler.submit` queues a job once (a second submission warns and returns it); `DotHashJob` checks `is_open()` before each read and ends on an empty read, never calling `eof_reached()`. `examples/scheduler_selftest.tscn` runs each case with real threads, and fails (section 1 by crashing) without the fix.

## Some calls are the damage

`OS.get_unique_id()` on web or iOS pushes `OS::get_unique_id() is not available on the Web platform` and then returns "". Callers in dot-auth, dot-server and dot-user checked for emptiness and fell back correctly, after printing a red engine error on the player's page. `DotPlatform.has_unique_id()` and `unique_id()` ask first. Found by loading the browser client.

## `push_warning` staples a backtrace on

In a debug build the engine appends an `at:` line and a full GDScript backtrace to every `push_warning` / `push_error`, with no per-call switch (`Engine.print_error_messages = false` silences real errors too). So **`DotLog` mirrors only ERROR and above into the engine** (`mirror_min_level`); at WARN every recoverable warning became eight lines of stderr that read like a crash. Set it to `Level.WARN` while hunting one warning's origin.

## `HTTPRequest` has no append mode

A ranged body written straight to the destination replaced the partial with its own tail, and `DotHttp.download_to_file` returned `ok`, `resumed: true` and a plausible status. Only the bytes on disk showed it, which is why `http_selftest` runs a real server ([transports.md](transports.md#dothttp)).
