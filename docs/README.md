# dot-core docs

| File | Subject |
| --- | --- |
| [engine-traps.md](engine-traps.md) | `DotValue`, `JavaScriptObject`, worker-thread signals, one thread per job and `eof_reached()`, `unique_id`, why `DotLog` mirrors only ERROR, the `HTTPRequest` resume bug |
| [transports.md](transports.md) | Platform constraints, `DotTransportDual` and the UDP demux, the ENet fixes, `DotMeteredPeer`, `DotHttp` |
| [http-server.md](http-server.md) | `DotHttpServer`: what it is and is not, limits and status codes, routes, static files, TLS, secrets |
| [addon-api.md](addon-api.md) | `DotAddonApi`, the per-addon `LEVEL`/`OLDEST` rule, `requires.json` |
| [randomness.md](randomness.md) | `random/`: the (key, index) idea, the mixer's three traps, who still hand-rolls a generator |
| [camera.md](camera.md) | `camera/`: why not `SpringArm3D`, the look-ahead sweep, fading people instead of colliding with them, the armed check |
| [loading.md](loading.md) | `loading/`: `DotLoadGate` (holds, requirements, freezing, the timeout), who covers the screen, `DotLoadingCover`, older shells |
| [addon-config.md](addon-config.md) | `DotAddonConfig`: `cfg/addon/<addon>/*.yml`, the roots, the layers, secrets |
| [dot-profile-split.md](dot-profile-split.md) | Done at API level 22: the profile classes moved to the dot-profile addon, class names kept; what was skipped and why |
| [profile.md](profile.md) | `profile/`: `DotHitchLog`, naming a lag spike from the frame split and counters |
