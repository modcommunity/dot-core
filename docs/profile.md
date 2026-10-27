# profile/

`DotHitchLog` records every frame longer than `threshold_ms` and what changed in it, so a lag spike gets a name instead of a guess. Create one, set `threshold_ms`, call `start(get_tree())`, optionally `mark("label")` for events you know about, and print `report()` (or read `summary()` / `hitches`). Window it on a GPU: software GL makes every frame a hitch.

Each hitch carries the frame's split (physics, script, render, wait) and the deltas of counters that betray the usual causes: `compile` (a pipeline built mid-frame, so a shader), `res` / `node` / `obj` (a load or an instantiate), `kb` (an allocation burst), `vram_kb`, `logs`, plus the roots of the subtrees added in it. Reading: all script with new nodes is an instantiate; all render with a compile delta is a shader; all wait is the frame cap or the GPU.

Wall time comes from `Time.get_ticks_usec()` at the engine's per-iteration signals, not from the smoothed `delta`. Check: `examples/hitch_log_selftest`. A game's capture tool: game-arena `tools/hitch_match`.

Fixes it found in Arena: weapon views prewarmed under the load gate (`ZeeViewModel.prewarm`), muzzle flashes (`DotMuzzleFlash.prewarm`) and `DotFxManager.warm` for the first explosion.
