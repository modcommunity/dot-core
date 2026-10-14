extends Node

## Exercises [DotJob], [DotScheduler] and [DotHashJob] across threads.
##
## [b]What it guards is a dedicated server that died mid map change.[/b] A hash job's
## worker logged `File must be opened before use` from `get_length`, then crashed with
## signal 11 in `eof_reached`: a second thread had been inside the same job and closed
## its file. Every check here runs real threads; the probe job sleeps inside its hooks so
## an overlap that a fast machine would hide is wide enough to land every run.
##
## [codeblock]
## godot --headless --path . res://examples/scheduler_selftest.tscn
## [/codeblock]

const SECTIONS := 5
const CHECKS := 22

const DIR := "user://scheduler_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0


## A job that records whether two threads were ever inside it at once.
class ProbeJob extends DotJob:
	var setup_usec := 2000
	var step_usec := 200
	var steps_to_finish := 40

	var setups := 0
	var steps := 0
	var overlaps := 0
	## Teardowns that ran while some thread was still inside a setup or a step.
	var torn_inside := 0

	var _inside := 0
	var _m := Mutex.new()

	func _in() -> void:
		_m.lock()
		_inside += 1
		if _inside > 1:
			overlaps += 1
		_m.unlock()

	func _out() -> void:
		_m.lock()
		_inside -= 1
		_m.unlock()

	func _setup() -> void:
		_in()
		_m.lock()
		setups += 1
		_m.unlock()
		OS.delay_usec(setup_usec)
		_out()

	func _step() -> bool:
		_in()
		OS.delay_usec(step_usec)
		_m.lock()
		steps += 1
		var done := steps >= steps_to_finish
		_m.unlock()
		_out()
		if done:
			_finish(DotResult.success(steps))
			return false
		return true

	func _teardown() -> void:
		_m.lock()
		if _inside > 0:
			torn_inside += 1
		_m.unlock()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-core scheduler self-test")
	_line("")

	DirAccess.make_dir_recursive_absolute(DIR)

	_test_closed_file()
	_test_two_threads_one_job()
	_test_cancel()
	await _test_submitted_twice()
	await _test_many_hash_jobs()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _test_closed_file() -> void:
	_section("A hash job whose file is closed under it fails; it does not crash")

	# Before the fix this section is the crash itself: `eof_reached()` on a closed file
	# dereferences null inside the engine, and the run ends with signal 11.
	var path := _write_file("closed.bin", DotHash.CHUNK_SIZE * 3 + 7)
	var job := DotHashJob.new(path)

	_check(job.step(), "the first step opens the file and leaves work to do")

	job._file.close()
	var more := job.step()

	_check(not more and job.is_settled(), "the next step settles the job")
	_check(job.result != null and not job.result.ok, "as a failure")
	_check(
		job.result != null and not job.result.ok
			and job.result.error.code == DotError.CODE_IO,
		"an IO failure, which a caller already handles"
	)


func _test_two_threads_one_job() -> void:
	_section("Two threads stepping one job take turns")

	# What a job queued twice, or stepped by two workers, looks like from inside: before
	# the fix both threads ran _setup, the second one's open dropped the first one's file,
	# and whichever finished first closed the file under the other.
	var job := ProbeJob.new()
	var gate := Semaphore.new()
	var threads: Array[Thread] = []

	for i in 2:
		var t := Thread.new()
		t.start(func() -> void:
			gate.wait()
			while job.step():
				pass
		)
		threads.append(t)

	gate.post(2)
	for t in threads:
		t.wait_to_finish()

	_check(job.overlaps == 0, "no two threads were ever inside it at once (%d overlaps)" % job.overlaps)
	_check(job.setups == 1, "it was set up once (%d)" % job.setups)
	_check(job.torn_inside == 0, "it was never torn down under a step (%d)" % job.torn_inside)
	_check(
		job.state == DotJob.State.DONE and job.result != null and job.result.ok,
		"and it finished"
	)


func _test_cancel() -> void:
	_section("Cancel from another thread never tears a job down under a step")

	var queued := ProbeJob.new()
	queued.cancel()
	_check(queued.state == DotJob.State.CANCELLED, "a job that never started settles at once")
	_check(
		queued.result != null and queued.result.error.code == DotError.CODE_CANCELLED,
		"with a cancelled result"
	)
	_check(queued.setups == 0, "and was never set up")

	# A step 40 ms long on a worker. cancel() must not wait for it: it is called from the
	# main thread, which is the frame.
	var running := ProbeJob.new()
	running.step_usec = 40_000
	running.steps_to_finish = 1_000
	var gate := Semaphore.new()
	var t := Thread.new()
	t.start(func() -> void:
		gate.post()
		while running.step():
			pass
	)
	gate.wait()
	OS.delay_usec(10_000)

	var before := Time.get_ticks_usec()
	running.cancel()
	var took_ms := float(Time.get_ticks_usec() - before) / 1000.0
	t.wait_to_finish()

	_check(took_ms < 20.0, "cancel() did not wait for the step in progress (%.1f ms)" % took_ms)
	_check(running.state == DotJob.State.CANCELLED, "the worker settled it at its next step")
	_check(running.torn_inside == 0, "and tore it down outside any step")


func _test_submitted_twice() -> void:
	_section("A job submitted twice runs once")

	var scheduler := DotScheduler.new()
	scheduler.thread_count = 4
	add_child(scheduler)

	var job := ProbeJob.new()
	var finished_for_it := [0]
	scheduler.job_finished.connect(func(j: DotJob) -> void:
		if j == job:
			finished_for_it[0] += 1
	)

	scheduler.submit(job)
	scheduler.submit(job)
	var res: DotResult = await scheduler.run(job)

	# One more frame, so a second completion (the bug) has its chance to be reported.
	await get_tree().process_frame
	await get_tree().process_frame

	_check(res != null and res.ok, "it finished")
	_check(job.setups == 1, "set up once (%d)" % job.setups)
	_check(job.overlaps == 0, "never run by two workers at once (%d overlaps)" % job.overlaps)
	_check(finished_for_it[0] == 1, "and reported finished once (%d)" % finished_for_it[0])

	scheduler.queue_free()
	await get_tree().process_frame


func _test_many_hash_jobs() -> void:
	_section("Many hash jobs over the same files on four workers, some cancelled")

	# The server's verify pass: every object already in the store, two acquisitions at
	# once, several of them hashing the same object. Cancels are thrown in right after
	# submission, which is the race that let the main thread close a file a worker had
	# just opened.
	var scheduler := DotScheduler.new()
	scheduler.thread_count = 4
	add_child(scheduler)

	var paths: Array[String] = []
	var hashes: Array[String] = []
	for i in 6:
		var p := _write_file("many_%d.bin" % i, 1 + i * 40_000)
		paths.append(p)
		hashes.append(str(DotHash.sha256_file(p).value))

	var jobs: Array[DotHashJob] = []
	var cancelled := 0
	for round in 60:
		for i in paths.size():
			var job := DotHashJob.new(paths[i], hashes[i])
			jobs.append(job)
			scheduler.submit(job)
			if (round + i) % 3 == 0:
				job.cancel()
				cancelled += 1

	var deadline := Time.get_ticks_msec() + 30_000
	while Time.get_ticks_msec() < deadline:
		var open := 0
		for job in jobs:
			if not job.is_settled():
				open += 1
		if open == 0:
			break
		await get_tree().process_frame

	var settled := 0
	var good := 0
	var cancels := 0
	var other := 0
	for job in jobs:
		if not job.is_settled():
			continue
		settled += 1
		if job.result.ok:
			good += 1
		elif job.result.error.code == DotError.CODE_CANCELLED:
			cancels += 1
		else:
			other += 1

	_check(settled == jobs.size(), "every job settled (%d of %d)" % [settled, jobs.size()])
	_check(cancels <= cancelled, "only cancelled jobs report cancelled (%d)" % cancels)
	_check(good + cancels == jobs.size(), "every other job hashed its file correctly (%d)" % good)
	_check(other == 0, "and none failed any other way (%d)" % other)

	scheduler.queue_free()
	await get_tree().process_frame


func _write_file(file_name: String, size: int) -> String:
	var path := DIR.path_join(file_name)
	var bytes := PackedByteArray()
	bytes.resize(size)
	for i in range(0, size, 101):
		bytes[i] = (i * 7 + size) % 256
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	DotWeb.sync_filesystem()
	return path


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
