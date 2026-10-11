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

`overrides` exists because a client and a server in one process share one set of addon files, so "an older client" can only be a claim. `examples/addon_api_selftest.tscn` asserts the sentences, not just `CODE_VERSION`.
