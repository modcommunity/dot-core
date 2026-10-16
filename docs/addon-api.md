# Which addon API a build has: `DotAddonApi`

**A delivered pack's scripts compile against the HOST's addons**, so a pack written against a newer addon than the client shell or server has does not fail with a sentence: it fails to parse mid-load, with an identifier that "is not declared in the current scope". `DotAddonApi` turns that into "This game needs dot-net API level 3 or newer; this server has level 2.", asked before a single script in the pack is loaded (dot-cloud asks between download and mount; dot-server-deploy's installer asks before switching versions).

## A level, not the release version

The tag's semver is honest only in a release: dot-ci stamps it into `plugin.cfg`, but a developer checkout is a symlink whose `plugin.cfg` says 0.1.0 whatever it holds, `plugin.cfg` is not a resource so an exported build does not carry it, and a tag moves for a bug fix that changes no API ("needs 0.4.1" would refuse a 0.4.0 host that runs the pack perfectly). A level committed in the addon's own source is the same number in all three places.

## The rule, for every addon

- `addons/<addon>/<addon>_api.gd` holds `const LEVEL` and `const OLDEST`, with **no `class_name`**, so sixty addons do not add sixty globals. dot-core's is `dot_core_api.gd`.
- **Bump `LEVEL` when you add anything a game could call**, and write what the level added in the file's comment.
- **Raise `OLDEST` to the new `LEVEL` when you remove or change something a game could have called**: every pack built before that no longer compiles.
- An addon with no api file is at level 1, the level everything was at when the scheme began.

## `requires.json`

A pack says what it needs at its root: `{"format": 1, "addons": {"dot_net": 3}}`. Nobody keeps it by hand: `addons/dot_core/tools/dot_requires.gd` derives it from the game's own files (every global class declared under `res://addons/<x>/` that a script, scene or resource names, and every literal `res://addons/<x>/` path) at the levels the building checkout has. "Built against" is conservative on purpose. dot-ci's `package.sh --pack` writes it into the pack; a game that commits its own keeps control of it and the release audits it instead (`--check`), failing on an addon used and not declared or a level above what the build has.

## An addon the game reaches only behind a presence check stays out

`derive` does not require an addon that every file naming it reaches by a literal `res://addons/<x>/` path handed to `load()` in a script that also asks `ResourceLoader.exists`, `FileAccess.file_exists`, `DirAccess.dir_exists_absolute`, `DotAddonApi.installed` or `DotAddonApi.build_level` (`derive_optional` lists them, and `dot_requires.gd` says so on stderr). A global class name, a `preload()`, or a scene or resource naming the path is compile-time and keeps it required. Comments are ignored, so a doc comment naming a class does not count. The check is per file: a script testing one path and loading another is the author's promise. This is how mg-dangerous-delivery uses natural-disasters for lightning when it is linked and runs on a shell that has no such addon. No API level change: `derive_optional` is tooling, and an older dot-core only over-requires, which refuses rather than misruns.

## `requires.floor.json`: asking less of an addon the game guards

"Built against" is wrong in one case: a game that asks the host first (`DotAddonApi.build_level("dot_ui") >= 2`) and keeps an older path for an older host. Its derived `requires.json` still asks for level 2, so the older host refuses the pack before the guard runs, and the older path is dead code. Such a game commits `requires.floor.json` at its root, the same shape as `requires.json`, naming only the guarded addons at the lowest level its older path runs on: `{"format": 1, "addons": {"dot_ui": 1}}`. `dot_requires.gd` lowers those addons to their floors when it writes or prints (`apply_floors`) and derives every other addon as before, so the list still keeps itself. Committing a whole `requires.json` instead would also work, but it is audited only for addons missing or overstated, never understated, so it goes silently stale low the first time the game calls a newer API unguarded.

`floor_audit` fails the run on a floor nothing backs: an addon the game no longer uses, a floor above the build's level, a floor below the build's `OLDEST` (a host at the build's own level would then refuse the pack), and a floor below the build's level with no file asking the host for that addon's level (`build_level("x")` or `level_of("x")`, found by `guarded()`). A game also runs `floor_audit` in its own suite, so a removed guard fails there before a release does. The floor cannot prove each newer call is behind the guard; that remains the game's promise, and the guard's suite (both levels) is where it is tested. A committed `requires.json` wins over a floor file. Needs dot-core API level 4 where the pack is built (dot-ci resolves a game's addons at main); an older dot-core ignores the file and the pack asks for the built levels, which an older host refuses rather than misruns.

`overrides` exists because a client and a server in one process share one set of addon files, so "an older client" can only be a claim. `examples/addon_api_selftest.tscn` asserts the sentences, not just `CODE_VERSION`.
