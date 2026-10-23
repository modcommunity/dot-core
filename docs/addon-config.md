# Addon configuration: `cfg/addons/<addon_name>/*.yml`

Every addon and pack keeps its tuning and settings in `cfg/addons/<addon_name>/`, and **all** `*.yml` files in that directory are read when the addon is installed in a game or server. `DotAddonConfig` is the reader; an addon calls it once and never opens a yml itself.

```gdscript
var res := DotAddonConfig.load_dir("dot-map", {"rotation": {"mode": "sequential"}})
if not res.ok:
    return res
var mode: String = DotAddonConfig.get_value(res.value, "rotation.mode", "sequential")
```

- `load_dir(addon_name, defaults := {}, sensitive := PackedStringArray()) -> DotResult`: value is the merged Dictionary (a copy; the defaults are not mutated).
- `get_value(cfg, "dotted.path", default)`; `dir_for(addon_name) -> String` (read-strongest: the directory a read finds first, possibly read-only); `write_dir_for(addon_name) -> String` (always `user://cfg/addons/<name>`, the only place to write; call `DotWeb.sync_filesystem()` after); `describe(addon_name := "")` / `describe_lines(...)` say which files and overrides the last load used.

## Folder names, the operator tier and the shim

The folder is the addon name with `-` as `_`: `load_dir("dot-map")` reads `cfg/addons/dot_map/` (`DotAddonConfig.folder_name`). The tiers, weakest first, each read in every root: `cfg/addons/<addon>/`, the game's `cfg/game/<game>/<addon>/` (only when `DotAddonConfig.game` is set; a game sets it once at start), the operator's `cfg/server/addons/<addon>/` and the operator's per-game `cfg/server/game/<game>/<addon>/`. The operator tiers mirror the stock tree, so nothing in `cfg/server/` shares a name with a file there. The old `cfg/server/<addon>/` is still read through `DotCfgLegacy` (one WARN per file, removal 2026-12-31). `file_layers(addon, file, extra_dir := "")` lists every existing copy of one file weakest first, for a reader that layers one named file itself (dot-map's `maps.yml`). `tier_dirs(addon, tier, extra_dir := "", for_game := "")` lists one tier's directories (a `*_SUBDIR` constant) for a reader that scans a folder of its own (dot-map's per-map files), and `apply_overrides(addon, merged)` applies the command-line and environment overrides to a dictionary in place and returns the `path <- source` lines. Secrets stay file-only in every layer; env and argv refusal is unchanged.

A file that moved from a flat `cfg/<file>.yml` is found through `DotCfgLegacy.find(old_path, new_path)`: the new path wins whole when it exists (never merged with the old); otherwise the old path is returned with one WARN per old path naming both and `DotCfgLegacy.REMOVE_AFTER` (2026-12-31). After that date the old path is ignored and one ERROR names it. Design: [dot-map/docs/cfg-layout.md](../../dot-map/docs/cfg-layout.md). The self-test expects one ERROR line on stderr for the expired case.

## One named file into a typed config: `apply_file`

An addon with a typed config class (a `DotVoteRules`, a `DotLogConfig`) reads one named file such as `vote.yml` through `DotAddonConfig.apply_file(addon, file_name, legacy_dir, apply)`, where `apply` is a `func(values: Dictionary, path: String) -> PackedStringArray` that sets its own properties and returns what it applied. The helper reads `cfg/addons/<folder>/`, the game tier, then `cfg/server/addons/<folder>/` and `cfg/server/game/<game>/<folder>/` (the strongest wins), falls back to a flat `legacy_dir/file_name` through `DotCfgLegacy` (one WARN) only while no new copy exists, and fails with `CODE_PARSE` naming the file on a bad yml. It never reads the environment or command line, so a secret key stays file-only: the addon then calls its own `apply_env` and `apply_cli`, which refuse sensitive keys. Needs dot-core API level 16 (the server and game tiers: 17).

## List files: replace by default, `merge: true` to add

A file that is a list (a map rotation) is not merged key by key. `replace_aware_layers(addon, file, extra_dir := "")` returns the layers of `file_layers` that apply, weakest first: a layer whose top level lacks `merge: true` replaces every weaker one, so an operator's `cfg/server/addons/dot_map/maps.yml` swaps the shipped list whole, and one that starts `merge: true` adds to it. The reader (dot-map's rotation file) parses the returned paths itself and honours an optional `remove: [ids]` after merging. `DotAddonConfig.merge(into, over)` is the public deep merge (maps by key, lists replaced whole).

`DotAddonConfig.config_root` is a `--config` root a host sets when it was handed its cfg directory some other way (dot-server-deploy does).

Operators: [dot-server-deploy/docs/operator-config.md](../../dot-server-deploy/docs/operator-config.md).

## Order

Files are sorted by file name; a later file's keys override an earlier one's. Maps merge key by key; a list or scalar is replaced whole. Number the files (`10-base.yml`, `20-event.yml`) to layer. Only `.yml` is read.

Layers, weakest first, as every `DotConfig`: defaults passed in < yml files < environment < command line.

## Where `cfg/` is

Weakest first, each merged over the last: `res://cfg` (shipped), `<executable dir>/cfg`, `user://cfg`, then `--config DIR` (files directly in `DIR`, so `DIR/addons/<name>/`). `dir_for` returns the strongest existing directory (read-strongest, maybe read-only), or the `write_dir_for` path when none exists; write only to `write_dir_for`. No scene path is involved.

## The user tier: a player's own mod layer

`user://cfg/user/addons/<addon>/<file>.yml` sits between the game tier and the operator's `server/addons/`, so `load_dir`, `file_layers` and `apply_file` read it with no change in the reader. It is **off** (`DotAddonConfig.user_tier_enabled`, default false); a solo or listen-host game calls `DotAddonConfig.set_user_tier(true)` (which also switches `DotProfileSet`), a dedicated server never does and a client turns it off on connecting, so a file on a player's disk never changes what a server says. `save_user(addon, file, {dotted path: value}, schema)` validates against the editor's schema array, merges into the file and calls `DotWeb.sync_filesystem()`; `reset_user(addon, file)` deletes the file; `user_paths` reads it even while the tier is off. Secrets stay file-only. dot-menu's `DotAddonConfigEditorScreen` edits through these. `examples/addon_config_selftest`.

## Environment and command line

Environment: `<ADDON>_<PATH>` upper-cased, `-` `.` `/` as `_` (`dot-map`, `rotation.mode` is `DOT_MAP_ROTATION_MODE`). Command line: `--dot-map.rotation.mode=random`. Only a key already present in the defaults or a file can be overridden, and only with a value of its own type (bool, int, float, string, list split on commas); anything else logs a WARN and is ignored. Keys are refused from both when any segment of the path, split on `_`, `-` and camelCase, holds the word `password`, `secret` or `token` (or a plural) or ends in the word `key` (`api_key` yes; `hotkey`, `keybind`, `key_repeat` no), so `secrets.name` and `auth.token.v` are refused too; so is anything the caller lists in `sensitive`. Keys that are not text or contain `.`, and empty maps, cannot be overridden. A `null` default takes the value as a yml scalar; an int accepts `1e3` or `1.0`; a list keeps the element type of the default's first element. A space-separated command line value (`--dot-map.rotation.mode random`) is not taken when it starts with `--`. When two leaves spell the same variable (`a_b.c`, `a.b_c`) the variable applies to neither and one WARN is logged; the command line still works.

## Exports drop the yml

Godot's exporter packs only resources and what `include_filter` names, so `res://cfg/addons/*.yml` is silently missing from an exported game or a web build unless every export preset has `cfg/*` (or `*.yml`) in `include_filter`. Add it to a game's `export_presets.cfg`, to `game.sh` export steps, to dot-ci's export jobs and to dot-game-template's presets; `DotAddonConfig.export_filter_hint()` returns the sentence for a tool to print. A missing directory is not an error, so nothing at runtime can tell you.

## Failures

A missing directory is not an error. A file that does not parse returns the `DotYaml` failure (`DotError.CODE_PARSE`, or `CODE_IO`) wrapped with the addon and file name, and logs ERROR on channel `addon_config`; a file whose top level is not a mapping is `CODE_PARSE`; a bad addon name (empty, `/`, `\`, `:`, `..`) is `CODE_INVALID`. The self-test expects one ERROR line on stderr for the bad-file case.
