extends Node

## Page side of tools/idb_probe.sh: how many user:// files survive a tab closed right after a burst of writes.
## Query: phase=write|count, mode=old|new (old = the engine's own save only; new = DotWeb.sync_filesystem, which
## also installs the pagehide/beforeunload/visibility flush), n=<files> (default 400), tail=<small files written two seconds after the sync call> (default 0), kb=<size each> (default 24).
## Prints "IDB WROTE n" or "IDB COUNT n bytes" on the console; the page driver (check.mjs) reads them.

const DIR := "user://idb_probe"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _query(key: String, fallback: String) -> String:
	var v := DotWeb.query_param(key)
	return fallback if v.is_empty() else v


func _run() -> void:
	if _query("phase", "write") == "count":
		var da := DirAccess.open(DIR)
		var n := 0
		var bytes := 0
		if da != null:
			for f in da.get_files():
				n += 1
				bytes += FileAccess.get_size(DIR.path_join(f))
		print("IDB COUNT %d %d" % [n, bytes])
		return
	var count := int(_query("n", "400"))
	var size := int(_query("kb", "24")) * 1024
	DirAccess.make_dir_recursive_absolute(DIR)
	var blob := PackedByteArray()
	blob.resize(size)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in size:
		blob[i] = rng.randi() & 255
	for i in count:
		var f := FileAccess.open("%s/obj_%04d.bin" % [DIR, i], FileAccess.WRITE)
		f.store_buffer(blob)
		f.close()
	if _query("mode", "new") == "new":
		DotWeb.sync_filesystem()
	else:
		var b: Object = DotWeb.bridge()
		if b != null and b.has_method("force_fs_sync"):
			b.call("force_fs_sync")
	# tail: files written after the first sync finished, the ones only the unload flush can still save.
	var tail := int(_query("tail", "0"))
	if tail > 0:
		await get_tree().create_timer(2.0).timeout
	for i in tail:
		var f2 := FileAccess.open("%s/tail_%04d.bin" % [DIR, i], FileAccess.WRITE)
		f2.store_buffer(blob.slice(0, 1024))
		f2.close()
	print("IDB WROTE %d" % (count + tail))
