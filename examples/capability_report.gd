extends Control

## Prints what this build can do, then exercises the pieces that can be tested
## without a network.
##
## Run it on each target you ship to. It is the fastest way to find out that your
## web export has no threads, or that your Android build's storage estimate comes
## back unknown — both of which change how dot-cloud behaves, and neither of which
## is visible from a desktop editor run.
##
## Headless-friendly: [code]godot --headless --path . --scene examples/capability_report.tscn[/code]

@export var scheduler_ref: DotNodeRef

@onready var _output: RichTextLabel = $Output

var _scheduler: DotScheduler


func _ready() -> void:
	DotLog.set_level(DotLog.Level.DEBUG)

	# A DotNodeRef that creates what it cannot find: this scene ships without a
	# DotScheduler node, and the ref makes one. A host project that already has
	# a scheduler points the ref at theirs instead, changing nothing here.
	if scheduler_ref == null:
		scheduler_ref = DotNodeRef.of_created(&"Scheduler", DotScheduler)

	var res := scheduler_ref.resolve(self)
	if res.ok:
		_scheduler = res.value as DotScheduler

	_report()
	await _exercise()


func _report() -> void:
	_line("[b]Platform[/b]")
	for l in DotPlatform.describe_lines():
		_line("  " + l)

	_line("")
	_line("[b]Storage[/b]")
	_line("  user dir         %s" % DotPaths.describe_user_dir())

	if DotPlatform.is_web():
		var est := await DotWeb.estimate_storage()
		if est.ok:
			var d: Dictionary = est.value
			_line("  browser quota    %s" % DotPaths.format_bytes(int(d.get("quota", 0))))
			_line("  browser used     %s" % DotPaths.format_bytes(int(d.get("usage", 0))))
		else:
			_line("  browser quota    unknown (%s)" % est.error.message)

	_line("")
	_line("[b]Transports[/b]")
	for t: DotTransport in [
		DotTransportWebSocket.new(),
		DotTransportENet.new(),
		DotTransportAuto.new(),
	]:
		var avail := t._is_available()
		_line("  %-12s %s" % [
			t._transport_name(),
			"available" if avail.ok else "unavailable — " + avail.error.message,
		])


func _exercise() -> void:
	_line("")
	_line("[b]Self-test[/b]")

	# Path sanitisation: the traversal must be refused, not cleaned up.
	var bad := DotPaths.safe_relative("../../etc/passwd")
	_line("  traversal        %s" % (
		"refused" if not bad.ok else "ACCEPTED — this is a bug"
	))

	var good := DotPaths.safe_relative("games/dm_arena/map.pck")
	_line("  normal path      %s" % (
		"accepted" if good.ok else "REFUSED — this is a bug"
	))

	# Hashing, through the scheduler, on a file we write ourselves.
	var probe_path := "user://dot_core_selftest.bin"
	var payload := DotHash.random_bytes(3 * 1024 * 1024)
	var written := DotPaths.write_bytes(probe_path, payload)

	if not written.ok:
		_line("  hash job         could not write probe: %s" % written.error.message)
	elif _scheduler == null:
		_line("  hash job         no scheduler")
	else:
		var expected := DotHash.sha256_bytes(payload)
		var job := DotHashJob.new(probe_path, expected)

		var started := Time.get_ticks_msec()
		_scheduler.set_boost(10.0)
		var hashed := await _scheduler.run(job)
		var elapsed := Time.get_ticks_msec() - started

		_line("  hash job         %s (%d ms, %s)" % [
			"matched" if hashed.ok else "FAILED: " + hashed.error.message,
			elapsed,
			"threaded" if DotPlatform.has_threads() else "sliced on main thread",
		])

		DirAccess.remove_absolute(probe_path)

	# Rate limiter: 5 permitted from a burst of 5, the sixth refused.
	var limiter := DotRateLimiter.new(1.0, 5.0)
	var allowed := 0
	for _i in range(10):
		if limiter.allow("probe"):
			allowed += 1
	_line("  rate limiter     %d/10 allowed, retry in %.1fs" % [
		allowed, limiter.retry_after("probe")
	])

	# Address parsing, including the IPv6 case that a naive split gets wrong.
	for addr in ["1.2.3.4", "1.2.3.4:27015", "[::1]:27015", "wss://x.dev/game"]:
		var p := DotTransport.normalise_address(addr, 27015)
		_line("  parse %-18s -> host=%s port=%d%s" % [
			addr, p["host"], p["port"],
			" scheme=" + str(p["scheme"]) if str(p["scheme"]) != "" else "",
		])

	_line("")
	_line("[b]done[/b]")

	if DotPlatform.is_headless():
		# Give the log sink a chance to flush before the process ends.
		await get_tree().process_frame
		get_tree().quit()


func _line(text: String) -> void:
	# Printed as well as displayed so a headless run is useful.
	print(text.replace("[b]", "").replace("[/b]", ""))
	if _output != null:
		_output.append_text(text + "\n")
