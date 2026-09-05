class_name DotJob
extends RefCounted

## A unit of long-running work that can be advanced in slices.
##
## [b]Why not just use a [Thread].[/b] Single-threaded web builds have no
## threads at all, and the two most expensive things dot-cloud does — hashing a
## few hundred megabytes and scanning a cache directory — must not freeze the
## frame on any platform. A job that exposes [method step] can be driven by a
## [DotScheduler] inside a per-frame time budget on web and handed to a worker
## thread on desktop, from one implementation.
##
## Subclasses override [method _step] and report progress. The contract:
## [method _step] does a bounded amount of work and returns [code]true[/code]
## when there is more to do.
##
## [codeblock]
## class CountJob extends DotJob:
##     var _i := 0
##     func _step() -> bool:
##         _i += 1
##         if _i >= 1000:
##             _finish(DotResult.success(_i))
##             return false
##         return true
##     func _progress() -> float:
##         return float(_i) / 1000.0
## [/codeblock]

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


# --- Subclass hooks --------------------------------------------------------

## Does a bounded slice of work. Returns true if more remains.
##
## Must be cheap enough that one call cannot blow the frame budget on its own —
## the scheduler can stop calling it, but it cannot interrupt it. Hash a chunk,
## not a file.
func _step() -> bool:
	_finish(DotResult.fail(
		DotError.CODE_INTERNAL, "DotJob._step() was not overridden."
	))
	return false


## Completion in the range 0..1, or -1 when genuinely unknown.
##
## Return -1 rather than a fake value for work with no knowable extent (a
## directory walk of unknown size); progress UI shows an indeterminate bar for
## -1, which is honest, instead of a bar that jumps backwards.
func _progress() -> float:
	return -1.0


## Called once before the first [method _step], on whichever thread will run it.
func _setup() -> void:
	pass


## Called once after the job settles, on whichever thread settled it.
##
## For releasing resources the job owns — closing a [FileAccess], dropping a
## context. Thread-safe engine APIs only: anything touching the scene tree
## belongs in a [signal finished] handler, which is always delivered on the main
## thread.
func _teardown() -> void:
	pass


## Whether this job may run on a worker thread.
##
## Override to false for work touching the scene tree or any non-thread-safe
## engine API. Godot's [FileAccess] and [HashingContext] are safe off-thread;
## anything that adds nodes or loads scenes is not.
func is_thread_safe() -> bool:
	return true


# --- Driving ---------------------------------------------------------------

## Advances the job. Returns true while more work remains.
##
## Called by [DotScheduler]. Safe to call directly for a synchronous run, but
## prefer [method run_to_completion] which handles setup and cancellation.
func step() -> bool:
	if state == State.PENDING:
		state = State.RUNNING
		_setup()

	if state != State.RUNNING:
		return false

	if cancel_requested:
		_settle(
			State.CANCELLED,
			DotResult.fail(DotError.CODE_CANCELLED, "Cancelled.")
		)
		return false

	return _step()


## Runs the whole job on the calling thread, ignoring frame budget.
##
## For headless tools and tests. Never call it on the main thread of an
## interactive build: that is exactly the freeze the job design exists to avoid.
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


func cancel() -> void:
	if state == State.DONE or state == State.CANCELLED:
		return
	cancel_requested = true
	# A job that has not started yet will never be stepped, so settle it now
	# rather than leaving a queued job whose `finished` signal never fires.
	if state == State.PENDING:
		_settle(
			State.CANCELLED,
			DotResult.fail(DotError.CODE_CANCELLED, "Cancelled before start.")
		)


func is_settled() -> bool:
	return state == State.DONE or state == State.CANCELLED


func progress() -> float:
	return _progress()


## Emits [signal progressed] if the value moved meaningfully.
##
## Called by the scheduler. The 0.001 threshold keeps a job with a million steps
## from emitting a million near-identical signals into UI that redraws on each.
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


func _settle(new_state: State, res: DotResult) -> void:
	if is_settled():
		return
	state = new_state
	result = res
	_teardown()
	_emit_on_main_thread(finished, res)


## True when the caller is the main thread.
static func on_main_thread() -> bool:
	return OS.get_thread_caller_id() == OS.get_main_thread_id()


## Emits a signal on the main thread, deferring if we are on a worker.
##
## [b]Not a precaution — a correctness requirement.[/b] GDScript resumes an
## awaiting coroutine synchronously inside [method Signal.emit], on whatever
## thread called it. A job finishing on a [DotScheduler] worker would therefore
## resume [code]await job.finished[/code] on that worker, and the very next line
## of ordinary-looking caller code — appending to a label, adding a node,
## mounting a pack — would touch the scene tree off-thread. Godot catches some of
## those with an error and races on the rest.
##
## Deferring costs at most one frame of latency on the completion signal, and
## makes [code]await[/code] mean the same thing regardless of where the work ran.
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
