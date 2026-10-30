# Cameras that stay out of the level

`camera/` holds what every third-person, chase, death and spectator camera in the family uses to stay out of walls and out of people. It is in dot-core because the cameras that need it live in games and in addons that cannot depend on each other: dot-player-controller's orbit rig, dot-spectate's chase and death cameras (as a transform), and games such as the delivery game whose chase camera follows a vehicle and links no controller at all.

## Why not SpringArm3D

Every third-person view in the family used one, and the first play test (2026-10-11) still had a death camera inside a wall, a chase camera inside a cliff and inside a checkpoint arch, and players' heads filling the screen. Three things about the engine's spring arm caused it:

- **It casts a ray unless it is given a shape.** A ray slips through the slit between an arch's pillar and its beam, or between two boxes a map built a cliff from, and the camera ends with its near plane inside both. `DotCameraProbe` sweeps a sphere and also casts a ray down the same line, because `cast_motion` ignores anything the sphere already overlaps at the pivot.
- **It snaps.** The hit appears on one frame and the camera is at it on that frame; it disappears and the camera is back. See the look-ahead below.
- **It excludes nothing unless told.** Every arm hung off a player collapsed into that player until each game learned to exclude it (dot-player-controller's [design](../../dot-player-controller/docs/design.md#the-third-person-half) has that story). The probe's sweeps start inside the player's own capsule and both ignore a shape they start in, so the own body cannot stop it; exclusions are still taken, for a vehicle whose roof the pivot sits above.

## The look-ahead: smooth without being late

One sweep along the line as it is gives the hard limit, applied on every frame: the camera is never further out than it. Eight more sweep the line as it will be at four moments over the next `look_ahead` seconds (0.2), read two ways from how the line moved since the last frame: turned about the pivot at the rate it turned (an orbit; a straight-line extrapolation of the camera's end cuts the corner of the arc and misses the pillar the arc meets) and slid in a straight line (a strafe past a pillar); the nearest answer, as a fraction of its own line, is where the camera eases toward (`pull_in_time` 0.1 s), and never slower than the steady pace that has it inside every predicted limit by the moment that limit was predicted for: the ease alone got most of the way to a pillar arriving in a tenth of a second, and the rest was a 0.53 m cut. A pillar the view is swinging toward has already brought the camera in when the hard limit arrives, and a camera standing still rests exactly at the hard limit, because every predicted line is the current one.

Two things that were tried first and are wrong:

- **A wider sphere as the early warning.** It rests the camera in front of every wall by the difference in radius, and much further in front of a surface met at a glancing angle (a low ceiling with the camera pitched up came in by 0.7 m).
- **One look-ahead sample at the end of the interval.** A line moving at a running pace steps right over a 0.6 m pillar between now and 0.2 s from now; the samples have to cover the interval.
- **Only a straight-line extrapolation.** Flown round wipeout's machinery it let one 0.53 m cut through in 5,580 frames; the orbit is a turn.

Only an obstacle that appears faster than the look-ahead (a door slamming behind the head, a teleport) makes the hard limit cut, and a cut is the right answer there. `last_snap()` reports how far the hard limit cut the eased answer. Going back out is slower (`ease_out_time` 0.3 s), because a camera that springs out the moment a pillar is passed swings in and out along a colonnade. A pivot that moved more than `cut_distance` (4 m) between calls is a cut and starts at the answer.

## People are faded, not collided with

A camera that stopped against every body would pull into the player's head each time a bot walked behind them, and a crowd would pin it there. `DotCameraFade` sits under the camera and runs two tests a frame: a sphere of `near` (0.25 m) at the camera, where any body is hidden outright (transparency 1: "a face fills the screen"; small enough that a player standing shoulder to shoulder with you does not vanish), and in third person a capsule along the line to `focus`, stopped short of it so the watched body is never on it, where a body goes to `faded` (0.7: you still want to know somebody is standing there). What fades is every `GeometryInstance3D` under the hit body (or under what `root_fn` names), skipping any `Camera3D` subtree, because a first-person camera parented to a body carries that body's view model. Put the mask on character layers only, never the level. Characters that are not in the physics space at all (a game that collides players analytically, remote figures with no collider on a client) are handed over by `bodies_fn` and tested as upright capsules of `body_radius` and `body_height` on their origins.

## The check, armed

`examples/camera_selftest` flies a boom down a colonnade and under a low ceiling at a running pace while swinging it: no frame inside geometry, no cut of 0.3 m. Both are armed: the same flight with no probe must put the wanted point inside geometry on many frames, and with `look_ahead = 0` the hard limit must snap. A path that never goes near a wall passes a "never inside" check for the one reason it cannot fail.

`DotCameraCheck` is the same check for a game's own level: `orbit_path` turns a camera round a pivot (a spawn) with the pitch swinging, `pivots_near_walls` finds pivots on a grid where a wall is close (an open floor proves nothing), `fly` asks every frame where the camera wanted to be and where the probe put it, and `passed` needs the first in or behind the level on some frame and the second inside on none, with no snap. `DotCameraTool` is a `SceneTree` base a game's `tools/render_cameras.gd` extends with its level, pivots and camera offsets: it flies them, exits 1 on a failure, and under a renderer draws the worst frame before and after, a body between the camera and the player plain and faded, and a body walking into a first-person camera plain and faded (`screenshots/cameras/`). `--no-render` flies only, headless.


## Drawing materials once before play: DotRenderWarmup

A renderer compiles a material's shader the first time something using it is drawn, and under the Compatibility renderer (every browser) the compile and the link are synchronous on the only thread: the first frame of a map, the first shot and the first kill each stall. Nothing compiles a shader without drawing it, so `DotRenderWarmup` draws it: `collect(root)` gathers every mesh and material a subtree uses (surface, override and overlay materials, particle process materials and draw passes), `add_items` takes those plus anything not in the tree yet, and `start()` puts each on a half-millimetre instance just past the parent camera's near plane for two frames, then frees itself and emits `finished`.

- **Why it is invisible and still works**: culling is by bounds on the CPU, not by covered pixels, so a sub-pixel quad inside the frustum is submitted and its program built exactly as a full-screen one would be.
- **Why a mesh is drawn as itself** rather than its materials on a quad: the vertex format is part of the shader variant.
- **What it misses**: variants that depend on what draws the surface. A skinned mesh warms its unskinned variant, and a light that appears later (a muzzle flash) adds variants nobody drew. It removes most first-use stalls, not all.
- **It never waits for ever**: headless or in a hidden window nothing is drawn, so `timeout_sec` (5 s without a drawn frame) finishes it anyway; a loading screen held on `finished` always lifts.
- **It draws in rounds**: `batch_size` (1000) items per round, each up `frames` frames. One round of a big map's 18,000 draws was a single 2.4 s frame on a fast GPU, long enough on a slow one for the OS to call the window not responding; rounds keep each frame near 130 ms. 0 restores one round.

The client shell (dot-server-deploy) runs it under its loading screen; `examples/camera_selftest` covers collection, placement and the timeout.

## Drawing a held model at its own lens: DotViewLens

A first-person model is drawn at its own vertical field of view (`hands_fov`) under whatever lens the camera has: `DotViewLens.apply(model, camera, hands_fov)` scales X and Y by the ratio of the two lenses and pulls the model toward the eye, never more than `MAX_PULL_IN`, so its apparent size at the reference lens is kept. `vertical_from_horizontal_4_3` turns a game's field-of-view setting (horizontal on a 4:3 frame) into the vertical one. zee-dot-weapons' `ZeeViewModel` and dot-props' `DotToolView` both call it.
