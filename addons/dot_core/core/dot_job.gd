class_name DotJob
extends RefCounted

## A unit of long-running work that can be advanced in slices.
## Web has no threads and hashing or scanning must not freeze a frame: a [DotScheduler] drives [method step] in a budget, or a worker on desktop.
## Subclasses override [method _step] (bounded work, true while more) and [method _progress].

enum State {
	PENDING,   ## Queued, not started.
	RUNNING,
	DONE,      ## Finished; [member result] is set.
	CANCELLED,
}

## Emitted exactly once when the job reaches [constant State.DONE] or
## [constant State.CANCELLED]. Cancellation delivers a [constant DotError.CODE_CANCELLED]
## result rather than nothing, so [code]await job.finished[/code] always returns.
signal finished(result: DotResult)

## Emitted at most once per scheduler slice, not once per [method _step] — a
## hashing job stepping 4000 times a frame would otherwise spend more time
## emitting signals than hashing.
signal progressed(fraction: float)

var state: State = State.PENDING
var result: DotResult = null

## Free-form label for logs and progress UI.
var name: String = ""

## Set when the job should stop. Checked by the scheduler between slices;
## cooperative subclasses may also check it inside a long [method _step].
var cancel_requested: bool = false

var _last_reported_progress: float = -1.0

## Held for the whole of a [method step] and of a settle, so no two threads are inside one job at once.
## Without it a second thread closed a [DotHashJob]'s FileAccess under the worker and killed the server. Recursive, so a settle inside a step re-enters.
var _lock := Mutex.new()

## How deep the holder of [member _lock] is in it. Only touched while holding it.
var _held := 0

## A settle waiting for the lock to be released before [signal finished] goes out, so
## no listener is ever resumed inside the lock.
var _unsent: DotResult = null

## Set by [method DotScheduler.submit]. A job is queued once: a second submission, to
## the same scheduler or another, would put two workers in it.
var _submitted := false



## Does a bounded slice of work. Returns true if more remains.
## Cheap enough that one call cannot blow the frame budget: the scheduler cannot interrupt it. Hash a chunk, not a file.
func _step() -> bool:
	_finish(DotResult.fail(
		DotError.CODE_INTERNAL, "DotJob._step() was not overridden."
	))
	return false


## Completion in the range 0..1, or -1 when genuinely unknown.
## Return -1 for work with no knowable extent, so progress UI shows an indeterminate bar instead of one that jumps back.
func _progress() -> float:
	return -1.0


## Called once before the first [method _step], on whichever thread will run it.
func _setup() -> void:
	pass


## Called once after the job settles, on whichever thread settled it.
## Release owned resources here, thread-safe APIs only; scene-tree work belongs in a [signal finished] handler (main thread).
func _teardown() -> void:
	pass


## Whether this job may run on a worker thread.
## Override to false for scene-tree or non-thread-safe engine work; FileAccess and HashingContext are fine.
func is_thread_safe() -> bool:
	return true



## Advances the job. Returns true while more work remains.
## Called by [DotScheduler]; prefer [method run_to_completion] for a synchronous run.
## Thread-safe: a second thread waits for the step to end; a job that settled meanwhile answers false.
func step() -> bool:
	_enter()

	var more := false

	if state == State.PENDING:
		state = State.RUNNING
		_setup()

	if state == State.RUNNING:
		if cancel_requested:
			_settle(
				State.CANCELLED,
				DotResult.fail(DotError.CODE_CANCELLED, "Cancelled.")
			)
		else:
			more = _step()

	_leave()
	return more


## Runs the whole job on the calling thread, ignoring frame budget.
## For headless tools and tests; on an interactive main thread it is the freeze jobs exist to avoid.
func run_to_completion(max_steps: int = 100_000_000) -> DotResult:
	var steps := 0
	while step():
		steps += 1
		if steps >= max_steps:
			_settle(
				State.DONE,
				DotResult.fail(
					DotError.CODE_INTERNAL,
					"Job exceeded %d steps without finishing." % max_steps
				)
			)
			break
	return result


## Requests cancellation. Safe from any thread, never waits.
## The flag is set and the thread holding the lock settles the job at its next step boundary.
func cancel() -> void:
	if is_settled():
		return
	cancel_requested = true

	if not _lock.try_lock():
		return
	_held += 1

	# A job that has not started yet will never be stepped, so settle it now
	# rather than leaving a queued job whose `finished` signal never fires.
	if state == State.PENDING:
		_settle(
			State.CANCELLED,
			DotResult.fail(DotError.CODE_CANCELLED, "Cancelled before start.")
		)

	_leave()


func is_settled() -> bool:
	return state == State.DONE or state == State.CANCELLED


func progress() -> float:
	return _progress()


## Emits [signal progressed] if the value moved meaningfully.
## The 0.001 threshold stops a million-step job emitting a million signals into redrawing UI.
func report_progress() -> void:
	var p := _progress()
	if p < 0.0:
		return
	if absf(p - _last_reported_progress) < 0.001 and p < 1.0:
		return
	_last_reported_progress = p
	_emit_on_main_thread(progressed, p)


## Called by subclasses from [method _step] to complete successfully or not.
func _finish(res: DotResult) -> void:
	_settle(State.DONE, res)


## Settles the job once; [method _teardown] runs under the lock, so never while another
## thread is inside a step.
func _settle(new_state: State, res: DotResult) -> void:
	_enter()

	if not is_settled():
		state = new_state
		result = res
		_teardown()
		_unsent = res

	_leave()


func _enter() -> void:
	_lock.lock()
	_held += 1


## Releases one level of [member _lock], and sends [signal finished] once the last
## level is released.
func _leave() -> void:
	_held -= 1

	var send: DotResult = null
	if _held == 0:
		send = _unsent
		_unsent = null

	_lock.unlock()

	if send != null:
		_emit_on_main_thread(finished, send)


## True when the caller is the main thread.
static func on_main_thread() -> bool:
	return OS.get_thread_caller_id() == OS.get_main_thread_id()


## Emits a signal on the main thread, deferring if we are on a worker.
## A requirement: GDScript resumes an awaiting coroutine inside [method Signal.emit] on the emitting thread, so the caller's next line would touch the scene tree off-thread.
## Costs at most one frame and makes [code]await[/code] mean the same wherever the work ran.
func _emit_on_main_thread(sig: Signal, arg: Variant) -> void:
	if on_main_thread():
		sig.emit(arg)
	else:
		sig.emit.call_deferred(arg)


func _to_string() -> String:
	return "DotJob(%s, %s)" % [
		name if name != "" else get_class(),
		State.keys()[state],
	]
