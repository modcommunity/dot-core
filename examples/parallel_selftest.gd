extends Node

## Exercises [DotParallel]: the fork/join the server builds per-peer snapshots on.
##
## What it guards: that a pooled run returns exactly what the inline run does, slot for slot;
## that the pool really ran the tasks off the calling thread (a "threads on" mode that quietly
## ran inline would pass every equality check); and that [member DotParallel.verify] catches
## a task whose answer depends on the order the tasks ran in. Three ERROR lines on stderr
## from the verify section (one per slot) are expected and announced.
##
## [codeblock]
## godot --headless --path . res://examples/parallel_selftest.tscn
## [/codeblock]

const SECTIONS := 4
const CHECKS := 15

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_line("dot-core parallel self-test")
	_line("")

	var was_verify := DotParallel.verify
	DotParallel.verify = false

	_test_resolve()
	_test_pooled_matches_inline()
	_test_verify()
	_test_describe()

	DotParallel.verify = was_verify

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line("ERROR: %d of %d checks ran." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _test_resolve() -> void:
	_section("worker counts")
	var available := DotParallel.available()
	_line("  (pool %s, %d cores)" % ["available" if available else "unavailable", OS.get_processor_count()])
	_check(DotParallel.resolve_workers(0) == 0, "0 is off")
	var auto := DotParallel.resolve_workers(-1)
	_check(auto == 0 if not available else (auto >= 1 and auto <= DotParallel.AUTO_MAX),
		"-1 is the cores less one, at least 1 and at most AUTO_MAX (%d)" % auto)
	_check(DotParallel.resolve_workers(3) == (3 if available else 0), "a count is itself where the pool is available")


func _test_pooled_matches_inline() -> void:
	_section("pooled matches inline")
	# Enough work per task that the pool really spreads it, and a result that depends only on i.
	var task := func(i: int) -> Variant:
		var h := i
		for k in 20000:
			h = (h * 1103515245 + 12345 + k) & 0x7fffffff
		return [i, h]
	var inline := DotParallel.run(task, 16, &"selftest.pure", 0)
	var pooled := DotParallel.run(task, 16, &"selftest.pure", 4)
	_check(inline.size() == 16 and var_to_bytes(inline) == var_to_bytes(pooled),
		"sixteen slots, the same bytes inline and on four workers")
	_check(DotParallel.run(task, 0, &"selftest.pure", 4).is_empty(), "no tasks, no slots, no fork")

	var main_thread := OS.get_thread_caller_id()
	var who := func(i: int) -> Variant:
		var spin := 0
		for k in 50000:
			spin += k ^ i
		return OS.get_thread_caller_id()
	var threads := DotParallel.run(who, 8, &"selftest.threads", 4)
	var off_main := 0
	for id: int in threads:
		if id != main_thread:
			off_main += 1
	_check(off_main > 0 if DotParallel.available() else off_main == 0,
		"pooled tasks ran off the calling thread (%d of 8)" % off_main)
	var inline_threads := DotParallel.run(who, 8, &"selftest.threads", 0)
	_check(inline_threads.all(func(id: int) -> bool: return id == main_thread),
		"inline tasks ran on the calling thread")


func _test_verify() -> void:
	_section("verify")
	var compare := func(a: Variant, b: Variant) -> String:
		return "" if var_to_bytes(a) == var_to_bytes(b) else "%s against %s" % [a, b]
	var pure := func(i: int) -> Variant:
		return i * i

	DotParallel.verify = true
	var failures := DotParallel.verify_failures
	var runs := DotParallel.verify_runs
	var squares := DotParallel.run(pure, 6, &"selftest.verify", 4, compare)
	_check(DotParallel.verify_runs == runs + 1 and DotParallel.verify_failures == failures,
		"a pure task is run twice and passes")
	_check(squares == [0, 1, 4, 9, 16, 25], "and its answers are the forward run's")

	# Impure on purpose: each task takes the next number from a counter it shares, so its
	# answer is the order it ran in. Inline (workers 0), because on the pool this would be a
	# race rather than a reliable difference.
	_line("  (three DotParallel verify ERROR lines follow, on purpose)")
	var counter := {"n": 0}
	var impure := func(_i: int) -> Variant:
		counter["n"] = int(counter["n"]) + 1
		return counter["n"]
	var _slots := DotParallel.run(impure, 3, &"selftest.verify", 0, compare)
	_check(DotParallel.verify_failures > failures, "a task whose answer depends on order is caught")

	# Without a compare a task is taken to apply changes, and is never run twice.
	var calls := {"n": 0}
	var applying := func(_i: int) -> Variant:
		calls["n"] = int(calls["n"]) + 1
		return null
	var _a := DotParallel.run(applying, 5, &"selftest.verify", 0)
	_check(int(calls["n"]) == 5, "a task with no compare runs once per slot")
	DotParallel.verify = false


func _test_describe() -> void:
	_section("describe")
	var d := DotParallel.describe()
	var labels: Dictionary = d["labels"]
	_check(labels.has("selftest.pure") and int(labels["selftest.pure"]["calls"]) == 2,
		"figures per label (selftest.pure: 2 calls; the empty one is not a call)")
	_check(int(labels["selftest.pure"]["pooled"]) == (1 if DotParallel.available() else 0),
		"pooled and inline counted apart")
	var text := "\n".join(DotParallel.describe_lines())
	_check(text.contains("selftest.threads") and text.contains("cores"), "describe_lines names the labels")
	DotParallel.reset_stats()
	_check((DotParallel.describe()["labels"] as Dictionary).is_empty(), "reset_stats forgets them")


func _section(title: String) -> void:
	_section_count += 1
	_line("[%s]" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
