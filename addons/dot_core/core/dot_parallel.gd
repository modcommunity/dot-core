class_name DotParallel
extends RefCounted

## A fork/join that returns inside the tick: [code]count[/code] pure tasks, each writing only its
## own result slot, on the worker pool or inline. Not [DotScheduler]: the answer lands this tick.
## A task reads frozen data and writes only its return value: no node API, physics, [DotLog],
## signal, shared container or shared random stream, and no typed node array. Static, so
## [param workers] comes from the caller. See docs/engine-traps.md and server-threading.md.

const CHANNEL := "parallel"

## Most workers the automatic count ([code]workers = -1[/code]) asks for: the pool is shared
## with the engine and with [DotScheduler]'s threads, and the measured gain flattened well
## before the six cores of the box it was measured on.
const AUTO_MAX := 8

## Fork/join times kept per label, for [method describe]'s p99.
const _SAMPLES_KEPT := 256

## Test switch: run every task twice (reverse order, then as configured) and [method DotLog.error]
## on any slot that differs, catching order dependence or impure tasks. Only for a task given a
## [code]compare[/code]. [code]DOT_PARALLEL_VERIFY=1[/code] turns it on at the first [method run].
static var verify: bool = false

## Slots [member verify] found different, since the process started. What a suite asserts on,
## besides reading stderr.
static var verify_failures: int = 0

## Runs [member verify] has made.
static var verify_runs: int = 0

static var _env_read: bool = false
static var _stats: Dictionary = {}


## Whether a [method run] can use the worker pool. Off on web even with threads: waiting for
## a group task would block the page's main thread, which the browser forbids.
static func available() -> bool:
	return DotPlatform.has_threads() and not DotPlatform.is_web() \
		and OS.get_processor_count() > 1


## The worker count [param workers] means here: 0 when [method available] is false or
## [param workers] is 0; for -1, the processor count less one (the calling thread works too,
## by waiting), at most [constant AUTO_MAX]; otherwise [param workers] itself.
static func resolve_workers(workers: int) -> int:
	if workers == 0 or not available():
		return 0
	if workers < 0:
		return clampi(OS.get_processor_count() - 1, 1, AUTO_MAX)
	return workers


## Calls [code]task.call(i)[/code] for each [code]i[/code] in [code]0..count-1[/code] and returns
## the results by slot. On the pool when [method resolve_workers] of [param workers] is not 0,
## else a plain loop in index order, which is every suite's "off" half. [param compare]
## (func(a, b) -> String, empty when equal) lets [member verify] re-run; without it never re-run.
static func run(
	task: Callable, count: int, label: StringName, workers: int,
	compare: Callable = Callable()
) -> Array:
	var slots: Array = []
	if count <= 0:
		return slots
	slots.resize(count)

	if not _env_read:
		_env_read = true
		if OS.get_environment("DOT_PARALLEL_VERIFY") == "1":
			verify = true

	var n := resolve_workers(workers)
	var started := Time.get_ticks_usec()

	var reference: Array = []
	if verify and compare.is_valid():
		# Reverse order, so a task that reads a slot another task fills is caught: in the
		# forward run below that slot may already hold the answer, here it never does.
		reference.resize(count)
		for i in range(count - 1, -1, -1):
			reference[i] = task.call(i)

	if n > 0:
		# Writing different elements of an Array from different threads is safe; changing its
		# size is not, which is why every slot exists before the fork.
		var body := func(i: int) -> void:
			slots[i] = task.call(i)
		var group := WorkerThreadPool.add_group_task(body, count, mini(n, count), true, String(label))
		WorkerThreadPool.wait_for_group_task_completion(group)
	else:
		for i in count:
			slots[i] = task.call(i)

	var usec := Time.get_ticks_usec() - started

	if not reference.is_empty():
		verify_runs += 1
		for i in count:
			var difference: String = compare.call(reference[i], slots[i])
			if difference != "":
				verify_failures += 1
				DotLog.error(CHANNEL, "verify: task differs between a reverse inline run and a %s run" % ("pooled" if n > 0 else "forward inline"),
					{"label": String(label), "task": i, "count": count, "difference": difference})

	_note(label, count, n > 0, usec)
	return slots


static func _note(label: StringName, count: int, pooled: bool, usec: int) -> void:
	var entry: Dictionary = _stats.get(label, {})
	if entry.is_empty():
		entry = {
			"calls": 0, "items": 0, "pooled": 0, "inline": 0, "usec": 0,
			"samples": PackedInt64Array(), "next": 0,
		}
		_stats[label] = entry
	entry["calls"] = int(entry["calls"]) + 1
	entry["items"] = int(entry["items"]) + count
	if pooled:
		entry["pooled"] = int(entry["pooled"]) + 1
	else:
		entry["inline"] = int(entry["inline"]) + 1
	entry["usec"] = int(entry["usec"]) + usec
	var samples: PackedInt64Array = entry["samples"]
	if samples.size() < _SAMPLES_KEPT:
		samples.append(usec)
	else:
		samples[int(entry["next"])] = usec
		entry["next"] = (int(entry["next"]) + 1) % _SAMPLES_KEPT
	entry["samples"] = samples


## Forgets every figure [method describe] reports. For a probe that measures a window.
static func reset_stats() -> void:
	_stats.clear()


## Per label: calls, items, how many ran pooled and inline, and the mean and p99 of a whole
## run in microseconds (fork, the tasks and the join; the tasks dominate).
static func describe() -> Dictionary:
	var out := {
		"available": available(),
		"cores": OS.get_processor_count(),
		"verify": verify,
		"verify_failures": verify_failures,
	}
	var labels := {}
	for label: StringName in _stats:
		var entry: Dictionary = _stats[label]
		var samples: PackedInt64Array = (entry["samples"] as PackedInt64Array).duplicate()
		samples.sort()
		var p99 := 0
		if not samples.is_empty():
			p99 = samples[mini(samples.size() - 1, int(floor(float(samples.size()) * 0.99)))]
		labels[String(label)] = {
			"calls": entry["calls"],
			"items": entry["items"],
			"pooled": entry["pooled"],
			"inline": entry["inline"],
			"mean_usec": int(entry["usec"]) / maxi(1, int(entry["calls"])),
			"p99_usec": p99,
		}
	out["labels"] = labels
	return out


static func describe_lines() -> PackedStringArray:
	var d := describe()
	var out := PackedStringArray()
	out.append("parallel   %s, %d cores%s" % [
		"available" if d["available"] else "unavailable (inline only)", d["cores"],
		(", verify on, %d differences" % d["verify_failures"]) if d["verify"] else "",
	])
	var labels: Dictionary = d["labels"]
	var names := labels.keys()
	names.sort()
	for label: String in names:
		var e: Dictionary = labels[label]
		out.append("  %-16s %d calls, %d items, %d pooled / %d inline, mean %d us, p99 %d us" % [
			label, e["calls"], e["items"], e["pooled"], e["inline"], e["mean_usec"], e["p99_usec"],
		])
	return out
