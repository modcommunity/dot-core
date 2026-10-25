# Plan: splitting the profile classes out of dot-core

Status: dot-core side done (API level 22) and the `dot-profile` repository exists with the classes; consumers' `requires` and the family lists are still to do. Below is the plan, then what was done differently.

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

## What was done

- `dot-profile` was built by filtering dot-core's history to the profile paths (`git filter-branch`, no `git subtree`, since the paths are scattered), so `git log` there goes back through the dot-core commits. Layout `addons/dot_profile/{core,tools}`, level 1, requires dot-core >= 21.
- No shim: the files were deleted from dot-core in the same change (step 2's "shim is the move itself").
- `DotAddonConfig.save_user(..., schema)` and `set_user_tier` used the profile classes. dot-core now carries what they needed as public helpers: `DotYaml.emit`, `DotAddonConfig.set_nested`, `is_finite_value` and `check_field`. `DotProfileSet.user_tier_enabled` is now a property that reads `DotAddonConfig.user_tier_enabled`, so one call switches both.
- dot-core's API level is 22; OLDEST stays 1 because the class names are unchanged.
- Step 5 (`DotCoreProfileCompat`) is skipped on purpose: the classes no longer exist in dot-core, so a project with a consumer and no dot-profile fails to parse with `Identifier "DotProfileSet" not declared`, loudly and before any warn-once could run; a check that cannot name the classes has nothing to look for.

## Still to do (other repositories)

- Each consumer addon (dot-npc, dot-weapon, dot-player-class, dot-npc-ai-director, dot-menu, dot-spawn, dot-ui, dot-console, dot-net, dot-workbench) requires dot-profile (`dot_profile: 1` in its `requires.floor.json`).
- `dot-bootstrap/projects.tsv`, dot-server-deploy's `addons.yml` and `repo_url()` rows, and dot-ci's `scripts/check-profiles.sh`, which still runs `addons/dot_core/tools/profile_check.gd` (now `addons/dot_profile/tools/profile_check.gd`).
- Any selftest outside dot-core that names `DotProfileSet.user_tier_enabled`, and `--import` in every consumer.
