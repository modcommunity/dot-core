# `loading/`: the game is not ready to be seen yet

`DotLoadGate` is one node a game holds closed while its level, camera and players arrive, and that lifts a cover once they have. `DotLoadingCover` is the plain cover it shows when nothing else covers the screen. `examples/load_gate_selftest` is the suite.

## Why it exists

A delivered game is on screen the moment its scene is added. Its map usually arrives after signon, its camera after the local player spawns, its other players a snapshot or two later, and every material compiles the first time it is drawn (synchronously in a browser). Without a cover the player watches a half-built world, a body falling through floor that does not exist yet, and a stall at each first sight. The client shell already had a cover for a game that declared a duck-typed `ready_to_show` contract on its root; one game did. The gate makes the same thing a few lines for every game, and gives a cover outside the shell too (`./game.sh play`, a standalone run), where there was none.

## Using it

```gdscript
# The client's root, _ready():
gate = DotLoadGate.new()
add_child(gate)                                     # a child of the game's root
gate.hold(&"map", "Loading the map")                # until the level is built
gate.require(&"player", func() -> bool: return player != null, "Joining")
gate.warm_up(weapon_materials)                      # drawn once under the cover
# When the local body exists:
gate.freeze(player)                                 # stopped while closed, restored when open
# When the level is in:
gate.release(&"map")
# A map change: hold again. The cover returns and frozen nodes stop until it is released.
```

- `hold(reason, text)` / `release(reason)`: the gate is closed while any reason is held. The newest reason with text is the cover's status line.
- `require(reason, predicate, text)`: held until the predicate returns true, asked every frame. A predicate whose object is freed counts as met.
- `require_camera` (on by default) holds `camera` until a current `Camera3D` or `Camera2D` inside the game exists. A game with no camera turns it off.
- `settle_physics_frames` (3): once nothing is held, physics frames to wait so bodies land on collision built that frame.
- `set_progress(fraction, text)`: `-1` is "no fraction" (indeterminate bar).
- `freeze(node)`: the node's `process_mode` is `DISABLED` while closed and its own mode comes back when the gate opens, again after every re-close; freed nodes are forgotten, `unfreeze(node)` restores at once, and a gate that leaves the tree restores everything.
- `timeout_sec` (20): counted from each closing, after which the gate opens anyway with one `DotLog.warn` naming every reason still held. A game that never releases must not leave the player behind a picture.
- Signals: `closed` (again after having been open; the first, initial state is not announced), `ready_to_show` (nothing held; the warm-up starts), `opened`, `progress_changed(fraction, text)`.
- `DotLoadGate.of(node)` finds the gate from any node under the game (the gate puts `META` on its parent), else the registered one. It registers as `dot_load_gate`, or `dot_load_gate#<service_scope>`; `register_service = false` keeps a second gate in one process from replacing the first's entry.

## Who covers the screen

A host claims the job by putting `HOST_META` (`dot_load_gate_host`) on an ancestor of the gate, with an object that has `adopt_load_gate(gate)`. The gate calls it on entering the tree, shows nothing of its own, and after `ready_to_show` waits in `WARMING` for the host's `host_finished()` (at most `host_wait_sec`). A host that finds a gate later calls `hosted_by(host)`. dot-server-deploy's shell is such a host: its loading screen shows the gate's line and bar, and it draws the materials itself.

With no host the gate shows its own cover and, once nothing is held, runs `DotRenderWarmup` on the current `Camera3D` (the tree's materials plus `warm_up` items, capped by `warm_timeout_sec`) before lifting it. The warm-up runs with `PROCESS_MODE_ALWAYS` because the camera is usually under a body the gate froze, and a disabled warm-up never reaches its own timeout.

The cover is subclass-or-assign: assign `gate.cover` (any node with `show_cover()`, `hide_cover()`, `set_status(text)`, `set_progress(fraction)`), set `cover_scene`, override `_make_cover()`, or subclass `DotLoadingCover` and override `_build()`. It shows at full opacity in the frame it is asked to: a fade-in is a quarter of a second of exactly what it is covering.

## Older shells

A shell built before the gate looks only at the game root: `signal ready_to_show`, `is_ready_to_show()`, `warm_up_items()`. The gate adds `ready_to_show` to its parent as a user signal (unless the root declares its own, which it then leaves alone) and emits it when it opens, so such a shell still covers until then. It cannot add methods, so a root that wants an older shell to warm its extra items keeps a `warm_up_items()` that returns `gate.warm_items()`.

## Things that look wrong and are not

- The gate is `PROCESS_MODE_ALWAYS`: it must keep counting under a paused tree and over the nodes it froze.
- A hold during `WARMING` goes back to `CLOSED` without `closed` (it was never open); a host checks the gate's state after its warm-up and keeps its screen up if the gate is closed again, and the next `ready_to_show` warms again.
- A pack runs on the dot-core its shell carries. A game naming `DotLoadGate` needs dot-core API level 10 (its derived `requires.json` asks for it, and an older host refuses the pack rather than misrunning it).
- `load_gate_selftest` removes its `DotLog` sink in `_exit_tree`. With the sink left in `DotLog`'s static list the suite printed "0 failed" and then the process aborted at exit (`corrupted size vs. prev_size`, exit 134), in every section alone: the engine's teardown frees what the leftover Callable points at twice.
