#!/usr/bin/env bash
# IndexedDB lost-object probe: exports a tiny web build of this checkout's DotWeb (no JavaScriptBridge.eval; page side is
# addons/dot_core/web/dot_web.js) and, in headless Chromium, writes a burst of user:// files, closes the tab at once and
# counts what the next load finds. mode old = the engine's own save only; new = DotWeb.sync_filesystem (adds the
# pagehide/beforeunload/visibility flush of fd70f43). Needs godot with web templates (export), node with playwright-core
# (PW_CORE=<node_modules dir>) and chromium (CHROMIUM=<binary>) (check). The two halves may run on different hosts.
#   tools/idb_probe.sh export OUTDIR                    build the page into OUTDIR
#   tools/idb_probe.sh check OUTDIR [trials] [n] [kb] [tail]   serve OUTDIR and run both modes
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
G="${GODOT:-godot}"
cmd=${1:?usage: idb_probe.sh export|check OUTDIR}; out=${2:?OUTDIR}
case $cmd in
export)
    W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
    mkdir -p "$W/proj/addons" "$out"
    cp "$HERE"/tools/idb_probe/{main.tscn,run.gd} "$W/proj/"
    ln -s "$HERE/addons/dot_core" "$W/proj/addons/dot_core"
    printf 'config_version=5\n\n[application]\n\nconfig/name="idb-probe"\nrun/main_scene="res://main.tscn"\nconfig/features=PackedStringArray("4.7")\n' > "$W/proj/project.godot"
    cat > "$W/proj/export_presets.cfg" <<P
[preset.0]

name="Web"
platform="Web"
runnable=true
export_filter="all_resources"
export_path="$(cd "$out" && pwd)/index.html"
script_export_mode=2

[preset.0.options]

variant/extensions_support=false
variant/thread_support=false
html/export_icon=false
P
    timeout 240 "$G" --headless --path "$W/proj" --import >/dev/null 2>&1 || true
    timeout 300 "$G" --headless --path "$W/proj" --export-release Web 2>&1 | grep -vE "^(Godot Engine|$)" | tail -5 || true
    [ -f "$out/index.wasm" ] || { echo "FAIL no web export"; exit 1; }
    cp "$HERE/addons/dot_core/web/dot_web.js" "$out/"
    sed -i 's#<head>#<head>\n<script src="dot_web.js"></script>#' "$out/index.html"
    echo "exported $out" ;;
check)
    trials=${3:-5}; n=${4:-400}; kb=${5:-24}; tail=${6:-0}; port=${PORT:-8793}
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$out" >/dev/null 2>&1 & srv=$!
    trap 'kill $srv 2>/dev/null || true' EXIT
    sleep 1
    for mode in old new; do node "$HERE/tools/idb_probe/check.mjs" "http://127.0.0.1:$port/index.html" "$mode" "$trials" "$n" "$kb" "$tail"; done ;;
*) echo "usage: idb_probe.sh export|check OUTDIR" >&2; exit 2 ;;
esac
