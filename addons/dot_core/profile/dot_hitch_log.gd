class_name DotHitchLog
extends RefCounted

## Records every frame longer than a threshold with what changed during it, so a lag spike
## can be named instead of guessed at.
##
## [codeblock]
## var hitches := DotHitchLog.new()
## hitches.threshold_ms = 33.0
## hitches.start(get_tree())
## hitches.mark("killcam start")         # optional: a label attached to the current frame
## # ... later:
## for line in hitches.report(): print(line)
## [/codeblock]
##
## [b]What "what ran" means.[/b] The engine exposes no per-script timer, so each hitch carries
## the frame's split (physics, script, render, wait for vsync) and the deltas of counters that
## betray the usual causes: pipeline compilations (a shader built mid-frame), nodes and
## resources created or freed (an instantiate or a load), static memory (an allocation burst),
## draw calls, video memory, log lines written, and the labels [method mark] was given. A
## hitch whose split is all [code]script[/code] with new nodes is an instantiate; all
## [code]render[/code] with a compile delta is a shader; all [code]wait[/code] is the
## frame cap or the GPU.
##
## Wall time is read from [method Time.get_ticks_usec] at the engine's own per-iteration
## signals, not from the delta [method Node._process] gets, which is smoothed and clamped.

const CHANNEL := "dot.hitch"

## A frame at least this long is a hitch.
var threshold_ms := 33.0
## Hitches kept; the worst of the older ones is dropped first.
var keep := 400

var _tree: SceneTree = null
var _running := false
var _iter_start := 0
var _phys_start := 0
var _script_start := 0
var _pre_draw := 0
var _post_draw := 0
var _snap := {}
var _marks: Array[String] = []
var _added: Array[String] = []
var _added_roots := {}
var _nodes_added := 0
var _nodes_removed := 0
var _log_lines := 0
var _frame_serial := 0
var _t0 := 0
var _start_frames := 0

## Every hitch: {t, ms, physics, script, render, wait, deltas, marks, added}.
var hitches: Array[Dictionary] = []
var frames := 0
var worst_ms := 0.0
var _all_ms := PackedFloat32Array()


## Starts watching [param tree]'s frames.
func start(tree: SceneTree) -> void:
	if _running or tree == null:
		return
	_tree = tree
	_running = true
	_t0 = Time.get_ticks_usec()
	_iter_start = 0
	_snap = _read()
	var _a := tree.physics_frame.connect(_on_physics)
	var _b := tree.process_frame.connect(_on_process)
	var _c := RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	var _d := RenderingServer.frame_post_draw.connect(_on_post_draw)
	var _e := tree.node_added.connect(_on_added)
	var _f := tree.node_removed.connect(_on_removed)
	var _g := DotLog.signals().record.connect(_on_log)


func stop() -> void:
	if not _running:
		return
	_running = false
	if is_instance_valid(_tree):
		_tree.physics_frame.disconnect(_on_physics)
		_tree.process_frame.disconnect(_on_process)
		_tree.node_added.disconnect(_on_added)
		_tree.node_removed.disconnect(_on_removed)
	RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)
	RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	DotLog.signals().record.disconnect(_on_log)
	_tree = null


## Attaches [param label] to the frame in progress, for the event the caller knows about.
func mark(label: String) -> void:
	_marks.append(label)


## Hitches per minute over the whole recording.
func per_minute() -> float:
	var secs := (Time.get_ticks_usec() - _t0) / 1.0e6
	return hitches.size() * 60.0 / maxf(secs, 1.0)


## The [param p]th percentile frame time in ms (0..1), over every frame seen.
func percentile(p: float) -> float:
	if _all_ms.is_empty():
		return 0.0
	var sorted := _all_ms.duplicate()
	sorted.sort()
	return sorted[clampi(int(p * (sorted.size() - 1)), 0, sorted.size() - 1)]


## Human lines: the totals, then the worst [param top] hitches with their cause hints.
func report(top: int = 15) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("HITCH frames=%d hitches=%d (>=%.0f ms) per_min=%.1f worst=%.1f ms p50=%.1f p99=%.1f" % [
		frames, hitches.size(), threshold_ms, per_minute(), worst_ms, percentile(0.5), percentile(0.99)])
	var sorted := hitches.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ms > b.ms)
	for h: Dictionary in sorted.slice(0, top):
		out.append("HITCH t=%.1fs %.1f ms [phys %.1f script %.1f render %.1f wait %.1f] %s%s%s" % [
			h.t, h.ms, h.physics, h.script, h.render, h.wait, _fmt(h.deltas),
			(" marks=" + ", ".join(h.marks)) if not (h.marks as Array).is_empty() else "",
			(" new=" + ", ".join(h.added)) if not (h.added as Array).is_empty() else ""])
	return out


## The same totals as a Dictionary, for a tool that compares runs.
func summary() -> Dictionary:
	return {"frames": frames, "hitches": hitches.size(), "per_min": per_minute(),
		"worst_ms": worst_ms, "p50_ms": percentile(0.5), "p99_ms": percentile(0.99)}


func _fmt(d: Dictionary) -> String:
	var parts: Array[String] = []
	for k: String in d:
		parts.append("%s%+d" % [k, d[k]])
	return " ".join(parts)


func _read() -> Dictionary:
	var s := {
		"compile": (RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH)
			+ RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE)
			+ RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW)
			+ RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION)),
		"res": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"obj": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"node": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"kb": int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1024.0),
		"vram_kb": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024.0),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"added": _nodes_added, "removed": _nodes_removed, "logs": _log_lines,
	}
	return s


func _on_added(n: Node) -> void:
	_nodes_added += 1
	if _added.size() < 8 and n.get_parent() != null and not _added_roots.has(n.get_parent()):
		# Only the root of each new subtree: its children would fill the list with one scene.
		_added_roots[n] = true
		var script: Script = n.get_script()
		_added.append("%s(%s)@%.0fms" % [n.name, script.resource_path.get_file() if script != null else n.get_class(),
			(Time.get_ticks_usec() - _iter_start) / 1000.0])


func _on_removed(_n: Node) -> void:
	_nodes_removed += 1


func _on_log(rec: Dictionary) -> void:
	_log_lines += 1
	if _marks.size() < 6:
		_marks.append("log %s: %s" % [rec.get("channel", ""), String(rec.get("message", "")).left(48)])


func _on_physics() -> void:
	if _phys_start == 0:
		_phys_start = Time.get_ticks_usec()


func _on_pre_draw() -> void:
	_pre_draw = Time.get_ticks_usec()


func _on_post_draw() -> void:
	_post_draw = Time.get_ticks_usec()


func _on_process() -> void:
	var now := Time.get_ticks_usec()
	if _iter_start != 0:
		_finish(now)
	_iter_start = now
	_script_start = now
	_phys_start = 0
	_pre_draw = 0
	_post_draw = 0
	_marks.clear()
	_added.clear()
	_added_roots.clear()
	# The frame about to run is compared with this reading.
	_snap = _read()


func _finish(now: int) -> void:
	var wall := (now - _iter_start) / 1000.0
	frames += 1
	_all_ms.append(wall)
	worst_ms = maxf(worst_ms, wall)
	if wall < threshold_ms:
		return
	var cur := _read()
	var deltas := {}
	for k: String in cur:
		var d: int = int(cur[k]) - int(_snap.get(k, cur[k]))
		if d != 0 and k != "draws":
			deltas[k] = d
	# The window runs from one process_frame to the next: the previous frame's scripts and
	# draw, then this iteration's physics steps. Headless has no draw, so scripts take the rest.
	var phys := ((now - _phys_start) / 1000.0) if _phys_start != 0 else 0.0
	var script := 0.0
	var render := 0.0
	if _pre_draw != 0:
		script = (_pre_draw - _script_start) / 1000.0
		render = ((_post_draw if _post_draw != 0 else now) - _pre_draw) / 1000.0
	else:
		script = maxf(wall - phys, 0.0)
	hitches.append({"t": (_iter_start - _t0) / 1.0e6, "ms": wall, "physics": phys, "script": script,
		"render": render, "wait": maxf(wall - phys - script - render, 0.0), "deltas": deltas,
		"marks": _marks.duplicate(), "added": _added.duplicate()})
	if hitches.size() > keep:
		hitches.pop_front()
