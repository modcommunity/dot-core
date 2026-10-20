class_name DotParallel
extends RefCounted

## A fork/join that returns inside the tick: [code]count[/code] pure tasks, each writing only
## its own result slot, on the engine's worker pool or inline on the calling thread.
##
## [codeblock]
## var slots := DotParallel.run(func(i: int) -> Variant: return build(i),
##         chunks, &"net.snapshot", config.snapshot_workers, compare)
## for result in slots:          # index order, on the calling thread
##     apply(result)
## [/codeblock]
##
## [b]Not [DotScheduler].[/b] A [DotJob] is long background work with a lock per job and a
## [code]finished[/code] signal deferred to the main thread, so its answer lands a frame later.
## A server tick needs the answer before the tick ends: this is
## [method WorkerThreadPool.add_group_task] and [method WorkerThreadPool.wait_for_group_task_completion],
## with the calling thread blocked in between, so nothing else on that thread can move the
## world under a task.
##
## [b]What a task may do.[/b] Read data frozen before the fork, and write only the value it
## returns (or containers it created itself). No node API (a worker's read of
## [code]global_position[/code] returns zero with an error in a debug build and a racing value in
## a release one), no physics query, no [DotLog] (sinks run on the caller's thread), no
## signal, no write into a container another task can see, no draw from a shared random
## stream. Changes to long-lived state come back in the result and the caller applies them in
## index order, which is what makes the answer the same with any worker count.
##
## [b]Static, no autoload, no node[/b], and no process-wide worker count: [param workers] comes
## from the caller's own config, so a listen server and a client (or two servers) in one process
## never change each other's threading. Only [member verify] is process-wide, and only suites
## set it.
##
## See game-dev/docs: server-threading.md (the design), and docs/engine-traps.md here.

const CHANNEL := "parallel"

## Most workers the automatic count ([code]workers = -1[/code]) asks for: the pool is shared
## with the engine and with [DotScheduler]'s threads, and the measured gain flattened well
## before the six cores of the box it was measured on.
const AUTO_MAX := 8

## Fork/join times kept per label, for [method describe]'s p99.
const _SAMPLES_KEPT := 256

## Test switch: run every task twice, inline in reverse index order and then as configured,
## and [method @GlobalScope.push_error] on any slot that differs. Catches a task that reads
## another task's slot, a result that depends on order, and a task that is not pure after all
## (its second run differs because its first one wrote something it then read).
##
## Only for a task given a [code]compare[/code]: one that applies changes (not pure on purpose)
## is never run twice. Off by default; [code]DOT_PARALLEL_VERIFY=1[/code] in the environment
## turns it on at the first [method run], so a suite runner can switch it on for a game whose
## scripts it does not edit.
static var verify: bool = false

## Slots [member verify] found different, since the process started. What a suite asserts on,
## besides reading stderr.
static var verify_failures: int = 0

## Runs [member verify] has made.
static var verify_runs: int = 0

static var _env_read: bool = false
static var _stats: Dictionary = {}


## Whether a [method run] can use the worker pool at all.
##
## [b]Off on the web, threads or not.[/b] A threaded web build has threads, and a browser can
## host a peer-to-peer game that builds snapshots, but
## [method WorkerThreadPool.wait_for_group_task_completion] would block the page's main thread,
## which the browser does not allow to wait. A one-core machine gains nothing from a pool.
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


## Calls [code]task.call(i)[/code] for [code]i[/code] in [code]0..count-1[/code] and returns
## the [param count] results, slot [code]i[/code] holding task [code]i[/code]'s, once every task
## has finished.
##
## On the worker pool when [method resolve_workers] of [param workers] is not 0 (with at most
## that many tasks running at once), else a plain loop in index order on the calling thread:
## the same tasks either way, so the inline path is the one every suite runs as its "off" half.
##
## [param label] groups the figures in [method describe]. [param compare] is
## [code]func(a, b) -> String[/code], empty when two results of the same task are the same and
## a description of the first difference otherwise; given one, [member verify] runs the tasks
## twice and compares. Without one the tasks are taken not to be pure and are never re-run.
##
## Call it from one thread at a time per set of data the tasks share; the pool itself is
## process-wide and safe to share.
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
				push_error("DotParallel verify: %s task %d of %d differs between a reverse inline run and a %s run: %s"
					% [label, i, count, "pooled" if n > 0 else "forward inline", difference])

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
