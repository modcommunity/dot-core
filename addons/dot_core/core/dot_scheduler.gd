@tool
class_name DotScheduler
extends Node

## Drives [DotJob]s inside a per-frame time budget, with optional worker threads.
##
## Place one anywhere in the tree (or let a [DotNodeRef] create it) and submit
## jobs. On desktop, thread-safe jobs go to a small worker pool; on
## single-threaded web builds — and for jobs that touch the scene tree —
## everything is sliced on the main thread inside [member frame_budget_ms].
##
## [b]The budget is the whole point.[/b] Verifying a 2 GB content cache is
## roughly 20 seconds of hashing. Doing it in one call drops the frame and
## Chrome offers to kill the tab; doing it in 2 ms slices spreads it over 20
## seconds of animated progress bar. The work takes the same time either way —
## only one of them looks like a working program.
##
## [codeblock]
## var job := DotHashJob.new("user://big.pck")
## scheduler.submit(job)
## var res: DotResult = await job.finished
## [/codeblock]

const CHANNEL := "sched"

## Emitted when the queue empties, for "all work done" gating.
signal idle()

## Emitted whenever a job settles, so a host can drive aggregate progress UI
## without tracking each job. Always delivered on the main thread.
signal job_finished(job: DotJob)

## Steps between progress reports for jobs running on a worker thread.
const PROGRESS_STEPS_ON_THREAD := 8

@export_group("Budget")

## Milliseconds per frame spent stepping main-thread jobs.
##
## 2 ms of a 16 ms frame is invisible; 8 ms is not, but finishes four times
## sooner. Loading screens raise this — see [method set_boost].
@export_range(0.1, 100.0, 0.1) var frame_budget_ms: float = 2.0

## Budget used while [method set_boost] is active.
##
## During a loading screen there is no gameplay to protect, so the only thing
## the budget still buys is a responsive progress bar and a browser that does
## not think the tab has hung.
@export_range(1.0, 500.0, 1.0) var boost_budget_ms: float = 12.0

## Steps between budget checks.
##
## Reading the clock per step measurably dominates cheap steps. Checking every
## 32 lets a pathological step overshoot by at most 31 more of itself, which for
## bounded steps is well inside the slack of a frame.
@export_range(1, 4096, 1) var steps_per_budget_check: int = 32

@export_group("Threading")

## Whether to use worker threads for [method DotJob.is_thread_safe] jobs.
##
## Ignored when [method DotPlatform.has_threads] is false.
@export var use_threads: bool = true

## Worker count. 0 means [code]min(4, processors - 1)[/code].
##
## Capped low on purpose: this pool exists for IO-bound hashing and file
## scanning, and saturating every core makes the frame worse, not better.
@export_range(0, 16, 1) var thread_count: int = 0

var _main_queue: Array[DotJob] = []
var _thread_queue: Array[DotJob] = []
var _threads: Array[Thread] = []
var _mutex: Mutex = Mutex.new()
var _semaphore: Semaphore = Semaphore.new()
var _shutting_down: bool = false
var _boost_until_ms: int = 0
var _running_on_threads: int = 0

## Jobs that settled on a worker and are waiting for main-thread teardown.
var _completed: Array[DotJob] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return

	if _threading_enabled():
		_start_threads()

	DotLog.debug(
		CHANNEL,
		"scheduler ready",
		{
			"threads": _threads.size(),
			"budget_ms": frame_budget_ms,
		}
	)


func _exit_tree() -> void:
	_shutdown_threads()


func _threading_enabled() -> bool:
	return use_threads and DotPlatform.has_threads()


func _resolved_thread_count() -> int:
	if thread_count > 0:
		return thread_count
	return maxi(1, mini(4, OS.get_processor_count() - 1))


# --- Submission ------------------------------------------------------------

## Queues a job. Returns it, so calls can be chained with [code]await[/code].
func submit(job: DotJob) -> DotJob:
	if job == null:
		push_error("DotScheduler.submit(null)")
		return job

	if job.is_settled():
		return job

	if _threading_enabled() and job.is_thread_safe():
		_mutex.lock()
		_thread_queue.append(job)
		_mutex.unlock()
		_semaphore.post()
	else:
		_main_queue.append(job)

	return job


## Queues a job and waits for it.
func run(job: DotJob) -> DotResult:
	submit(job)
	if job.is_settled():
		return job.result
	return await job.finished


## Queues several jobs and waits for all of them.
##
## Returns results in submission order regardless of completion order, because
## a caller zipping results back against its inputs must not have to sort them.
func run_all(jobs: Array[DotJob]) -> Array[DotResult]:
	for j in jobs:
		submit(j)

	var out: Array[DotResult] = []
	for j in jobs:
		if j.is_settled():
			out.append(j.result)
		else:
			out.append(await j.finished)
	return out


## Raises the frame budget for [param seconds].
##
## Call on entering a loading screen. Self-expiring rather than paired with a
## reset, because every early-return path out of a loading screen would
## otherwise be a place to leave the budget high forever.
func set_boost(seconds: float = 30.0) -> void:
	_boost_until_ms = maxi(
		_boost_until_ms, Time.get_ticks_msec() + int(seconds * 1000.0)
	)


func clear_boost() -> void:
	_boost_until_ms = 0


func pending_count() -> int:
	_mutex.lock()
	var n := _thread_queue.size() + _running_on_threads
	_mutex.unlock()
	return n + _main_queue.size()


func is_idle() -> bool:
	return pending_count() == 0


## Cancels everything queued. In-flight worker jobs settle as cancelled at their
## next step boundary.
func cancel_all() -> void:
	for j in _main_queue:
		j.cancel()
	_main_queue.clear()

	_mutex.lock()
	var pending := _thread_queue.duplicate()
	_thread_queue.clear()
	_mutex.unlock()

	for j in pending:
		j.cancel()


# --- Main-thread stepping --------------------------------------------------

func _process(_delta: float) -> void:
	_drain_completed()

	if _main_queue.is_empty():
		if is_idle():
			idle.emit()
		return

	var budget := frame_budget_ms
	if Time.get_ticks_msec() < _boost_until_ms:
		budget = boost_budget_ms

	# usec rather than msec: a 2 ms budget measured in whole milliseconds is
	# either 1 or 2, a 50% error.
	var deadline := Time.get_ticks_usec() + int(budget * 1000.0)
	var steps := 0

	while not _main_queue.is_empty():
		var job := _main_queue[0]

		if job.is_settled():
			_main_queue.pop_front()
			_finish_job(job)
			continue

		var more := job.step()
		steps += 1

		if not more:
			_main_queue.pop_front()
			job.report_progress()
			_finish_job(job)
			continue

		if steps % steps_per_budget_check == 0:
			job.report_progress()
			if Time.get_ticks_usec() >= deadline:
				return

	if is_idle():
		idle.emit()


func _finish_job(job: DotJob) -> void:
	if not job.is_settled():
		# A job whose _step returned false without calling _finish is a bug in
		# that job. Settle it rather than leaving an await that never returns.
		job._settle(
			DotJob.State.DONE,
			DotResult.fail(
				DotError.CODE_INTERNAL,
				"Job '%s' stopped without producing a result." % job.name
			)
		)

	job_finished.emit(job)


# --- Worker threads -------------------------------------------------------

func _start_threads() -> void:
	var n := _resolved_thread_count()
	for i in range(n):
		var t := Thread.new()
		t.start(_worker_loop)
		_threads.append(t)


func _shutdown_threads() -> void:
	if _threads.is_empty():
		return

	_shutting_down = true
	# One post per worker so each wakes, sees the flag, and returns.
	for _t in _threads:
		_semaphore.post()

	for t in _threads:
		if t.is_started():
			t.wait_to_finish()
	_threads.clear()


func _worker_loop() -> void:
	while true:
		_semaphore.wait()

		if _shutting_down:
			return

		_mutex.lock()
		var job: DotJob = null
		if not _thread_queue.is_empty():
			job = _thread_queue.pop_front()
			_running_on_threads += 1
		_mutex.unlock()

		if job == null:
			continue

		# Threads get no frame budget: there is no frame to protect, and the
		# whole reason to be here is to run flat out. Progress is still reported
		# periodically, otherwise a threaded job would show a frozen bar for its
		# whole duration — the opposite of why it was moved off the main thread.
		var steps := 0
		while job.step():
			steps += 1
			if steps % PROGRESS_STEPS_ON_THREAD == 0:
				job.report_progress()
			if _shutting_down:
				job.cancel()
				break

		# A cancelled RUNNING job does not settle itself — cancel() only settles
		# jobs that never started. Without this, shutdown leaves an `await
		# job.finished` that never returns and a caller blocked forever.
		if not job.is_settled():
			job._settle(
				DotJob.State.CANCELLED,
				DotResult.fail(
					DotError.CODE_CANCELLED, "Scheduler shut down."
				)
			)

		_mutex.lock()
		_running_on_threads -= 1
		_completed.append(job)
		_mutex.unlock()


## Emits worker-job completions on the main thread.
##
## Signals must not cross threads — a listener that touches the scene tree from
## a worker is a crash that reproduces once a week. Workers park settled jobs and
## this hands them over.
func _drain_completed() -> void:
	_mutex.lock()
	var done := _completed.duplicate()
	_completed.clear()
	_mutex.unlock()

	for job in done:
		_finish_job(job)


# --- Reporting ------------------------------------------------------------

func describe() -> Dictionary:
	_mutex.lock()
	var queued := _thread_queue.size()
	var running := _running_on_threads
	_mutex.unlock()

	return {
		"main_queue": _main_queue.size(),
		"thread_queue": queued,
		"thread_running": running,
		"threads": _threads.size(),
		"budget_ms": frame_budget_ms,
		"boosted": Time.get_ticks_msec() < _boost_until_ms,
	}
