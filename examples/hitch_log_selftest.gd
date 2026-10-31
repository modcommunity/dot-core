extends Node

## Exercises [DotHitchLog]: a deliberately slow frame is recorded with its mark and the nodes added in it, quiet frames are not, the report names it, and a [DotFrameCost] report pins it on a system.
##
## [codeblock]
## godot --headless --path . res://examples/hitch_log_selftest.tscn
## [/codeblock]

const SECTIONS := 4
const CHECKS := 24

var _passed := 0
var _failed := 0
var _section_count := 0
var _measured: Array[Dictionary] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_line("dot-core hitch log self-test")
	await _test_records_a_slow_frame()
	await _test_quiet_frames()
	await _test_report_and_stop()
	await _test_frame_cost()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections and %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _busy(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		pass


func _test_records_a_slow_frame() -> void:
	_section("A slow frame is a hitch, with its mark and the node added in it")
	var h := DotHitchLog.new()
	h.threshold_ms = 40.0
	h.start(get_tree())
	await get_tree().process_frame
	await get_tree().process_frame
	h.mark("the slow bit")
	var n := Node.new()
	n.name = "Spawned"
	add_child(n)
	_busy(80)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(h.hitches.size() == 1, "exactly one hitch", str(h.hitches.size()))
	if h.hitches.is_empty():
		h.stop()
		return
	var hit: Dictionary = h.hitches[0]
	_check(hit.ms >= 70.0, "its length is the busy time", "%.1f" % hit.ms)
	_check("the slow bit" in hit.marks, "the mark is attached")
	_check(hit.deltas.get("node", 0) >= 1, "the added node shows in the node delta")
	_check(hit.added.size() >= 1 and String(hit.added[0]).begins_with("Spawned"), "the new subtree root is named")
	_check(h.worst_ms >= 70.0, "worst_ms follows")
	h.stop()
	n.queue_free()


func _test_quiet_frames() -> void:
	_section("Frames under the threshold record nothing")
	var h := DotHitchLog.new()
	h.threshold_ms = 500.0
	h.start(get_tree())
	for i in 5:
		await get_tree().process_frame
	_check(h.hitches.is_empty(), "no hitches")
	_check(h.frames >= 3, "frames are still counted", str(h.frames))
	h.stop()


func _test_report_and_stop() -> void:
	_section("The report names the hitch; stop() ends recording")
	var h := DotHitchLog.new()
	h.threshold_ms = 30.0
	h.start(get_tree())
	await get_tree().process_frame
	await get_tree().process_frame
	_busy(60)
	await get_tree().process_frame
	await get_tree().process_frame
	var lines := h.report(5)
	_check(lines.size() == 2, "a totals line and one hitch line", str(lines.size()))
	_check(lines[0].begins_with("HITCH frames="), "the totals line leads")
	_check(lines.size() > 1 and " ms [phys " in lines[1], "the hitch line has the split")
	_check(h.summary().hitches == 1, "summary counts it")
	h.stop()
	var seen := h.frames
	_busy(60)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(h.frames == seen, "no frames counted after stop")
	_check(h.hitches.size() == 1, "no hitch recorded after stop")


func _on_measured(rec: Dictionary) -> void:
	_measured.append(rec)


func _test_frame_cost() -> void:
	_section("DotFrameCost charges a slow frame to the system that reported it")
	_check(DotFrameCost.now() == 0, "now() is 0 while disabled")
	DotFrameCost.add(&"ignored", 1)
	DotFrameCost.enabled = true
	var h := DotHitchLog.new()
	h.threshold_ms = 40.0
	var _c := h.frame_measured.connect(_on_measured)
	h.start(get_tree())
	await get_tree().process_frame
	await get_tree().process_frame
	var t := DotFrameCost.now()
	_busy(60)
	DotFrameCost.add(&"navigation", t, "rebuild paths")
	var t2 := DotFrameCost.now()
	_busy(5)
	DotFrameCost.add(&"ui", t2)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_measured.size() >= 3, "frame_measured fires every frame", str(_measured.size()))
	_check(h.hitches.size() == 1, "one hitch", str(h.hitches.size()))
	if h.hitches.is_empty():
		h.stop()
		DotFrameCost.reset()
		return
	var sys: Dictionary = h.hitches[0].get("systems", {})
	_check(not sys.has(&"ignored"), "a report made while disabled is dropped")
	_check(sys.has(&"navigation") and sys[&"navigation"].ms >= 55.0, "navigation carries the busy time", str(sys))
	_check(sys.get(&"navigation", {}).get("what", "") == "rebuild paths", "the worst call is named")
	_check(sys.has(&"ui") and sys[&"ui"].calls == 1, "a second system is counted apart")
	var emitted := _measured.filter(func(r: Dictionary) -> bool: return r.has("deltas"))
	_check(emitted.size() == 1 and emitted[0].systems.has(&"navigation"), "the hitch is emitted whole, with its deltas", str(emitted.size()))
	_check(h.report(1)[1].contains("systems=navigation"), "the report line leads with the costliest system", h.report(1)[1])
	h.stop()
	DotFrameCost.reset()
	_check(DotFrameCost.take().is_empty() and not DotFrameCost.enabled, "reset clears and disables")


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("--- %s ---" % title)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		_line("  ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL %s%s" % [what, ("  (" + detail + ")") if detail != "" else ""])


func _line(text: String) -> void:
	print(text)
