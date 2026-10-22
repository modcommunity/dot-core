# Addon configuration: `cfg/addons/<addon_name>/*.yml`

Every addon and pack keeps its tuning and settings in `cfg/addons/<addon_name>/`, and **all** `*.yml` files in that directory are read when the addon is installed in a game or server. `DotAddonConfig` is the reader; an addon calls it once and never opens a yml itself.

```gdscript
var res := DotAddonConfig.load_dir("dot-map", {"rotation": {"mode": "sequential"}})
if not res.ok:
    return res
var mode: String = DotAddonConfig.get_value(res.value, "rotation.mode", "sequential")
```

- `load_dir(addon_name, defaults := {}, sensitive := PackedStringArray()) -> DotResult`: value is the merged Dictionary (a copy; the defaults are not mutated).
- `get_value(cfg, "dotted.path", default)`; `dir_for(addon_name) -> String`; `describe(addon_name := "")` / `describe_lines(...)` say which files and overrides the last load used.

## Order

Files are sorted by file name; a later file's keys override an earlier one's. Maps merge key by key; a list or scalar is replaced whole. Number the files (`10-base.yml`, `20-event.yml`) to layer. Only `.yml` is read.

Layers, weakest first, as every `DotConfig`: defaults passed in < yml files < environment < command line.

## Where `cfg/` is

Weakest first, each merged over the last: `res://cfg` (shipped), `<executable dir>/cfg`, `user://cfg`, then `--config DIR` (files directly in `DIR`, so `DIR/addons/<name>/`). `dir_for` returns the strongest existing directory, or the `user://cfg` path when none exists. No scene path is involved.

## Environment and command line

Environment: `<ADDON>_<PATH>` upper-cased, `-` `.` `/` as `_` (`dot-map`, `rotation.mode` is `DOT_MAP_ROTATION_MODE`). Command line: `--dot-map.rotation.mode=random`. Only a key already present in the defaults or a file can be overridden, and only with a value of its own type (bool, int, float, string, list split on commas); anything else logs a WARN and is ignored. Keys whose last segment contains `password`, `secret`, `token` or `key`, or that the caller lists in `sensitive`, are refused from both, as `DotConfig.sensitive_keys()` does.

## Failures

A missing directory is not an error. A file that does not parse returns the `DotYaml` failure (`DotError.CODE_PARSE`, or `CODE_IO`) wrapped with the addon and file name, and logs ERROR on channel `addon_config`; a file whose top level is not a mapping is `CODE_PARSE`; a bad addon name (empty, `/`, `..`) is `CODE_INVALID`. The self-test expects one ERROR line on stderr for the bad-file case.
