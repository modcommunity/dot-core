# Plan: splitting the profile classes out of dot-core

Status: plan only. No code has moved. This page says how it would move without breaking a consumer.

## Why

`DotProfileSet`, `DotProfile` and `DotProfileRuntime` (see [profiles.md](profiles.md)) are a per-entity config system with its own tiers, `extends`, folders and validation. Only the entity addons use them (dot-npc, dot-weapon, dot-player-class, dot-npc-ai-director, dot-menu, dot-spawn, dot-ui, dot-console, dot-net, dot-workbench), and dot-core is the foundation every addon requires. Each addition to the profile system is an API bump for the whole family. A separate `dot-profile` addon would let it version on its own.

## Constraints

- Class names stay: `DotProfileSet`, `DotProfile`, `DotProfileRuntime`. `class_name` is global, so every consumer keeps compiling without an edit.
- The cfg paths and file formats do not change.
- dot-core itself uses the profile classes in places (`DotAddonConfig` callers, selftests); dot-core must not require dot-profile, since dot-profile would require dot-core.

## Steps

1. Create `dot-profile` with the three scripts, `docs/profiles.md` and the profile selftest, moved with `git mv`-style history kept by a subtree split. It requires dot-core at the API level that has `DotAddonConfig.merge` (17).
2. In dot-core, leave the three files as shims for one release cycle: the same `class_name` cannot exist in two addons, so the shim is the move itself. The files are deleted from dot-core in the same release that dot-profile ships, and dot-core's `dot_core_api.gd` raises its level.
3. Each consumer addon adds dot-profile to its `requires` (its `dot_*_api.gd` floor and `provides.json`/`requires.json`), and `dot-bootstrap/projects.tsv` and dot-server-deploy's `addons.yml` gain the new row.
4. A game that uses a profile-based addon gets dot-profile through that addon's requirement; there is nothing to change in its code.
5. Deprecation: for one release dot-core keeps a `DotCoreProfileCompat` check that logs once (`DotCfgLegacy`-style warn-once) when a project has the profile classes but not dot-profile in the addon list. Remove it on the date set in that release's notes.

## Order and risk

- Do the move in one pass: dot-profile, dot-core, then the ten consumers' requirements, because a project that has two copies of a global class fails to parse.
- Run every consumer's suite and `./game.sh test` in the reference game after the import cache is rebuilt (`--import`), since a moved `class_name` leaves a stale cache.
- Roll back by restoring the three files in dot-core; nothing else changes.

## Not done here

No repository exists yet, no consumer requires it, and no api level was changed.
