extends Node
## DotWeb's filesystem sync off the web: callable unguarded, counts no failures, does not error.
## The browser half (a failed IndexedDB save counted, logged and retried) is seen with tools/dev-env/web_check.mjs.
## Run: godot --headless --path . res://examples/web_selftest.tscn

const CHECKS := 17

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_check(not DotWeb.has_new_sync_failures(0, 0), "no failures is nothing new")
	_check(DotWeb.has_new_sync_failures(2, 1), "a higher count is new")
	_check(not DotWeb.has_new_sync_failures(1, 1), "the same count is not reported twice")
	# sync_failures() once called int() on the null eval returns off-web and errored.
	_check(DotWeb.sync_failures() == 0, "a desktop build has counted no failed saves")
	DotWeb.sync_filesystem()
	_check(true, "sync_filesystem is a no-op off-web")
	var flushed := await DotWeb.flush_filesystem(get_tree(), 2, 0.05)
	_check(flushed.ok, "flush_filesystem succeeds off-web")
	var none := await DotWeb.flush_filesystem(null)
	_check(none.ok, "and without a tree")
	_check(DotWeb.page() == null, "page() is null off-web")
	_check(not DotWeb.lock_keyboard().ok, "lock_keyboard reports no page off-web")
	_check(not DotWeb.post_to_parent({"type": "x"}).ok, "post_to_parent reports no page off-web")
	_check(not DotWeb.download_text("a", "a.txt").ok, "download_text reports no page off-web")
	_check(not DotWeb.set_tab_guard_armed(true).ok, "set_tab_guard_armed reports no page off-web")
	_check(not DotWeb.has_tab_guard() and not DotWeb.is_metered(), "no tab guard and not metered off-web")
	DotWeb.publish("k", "v")
	DotWeb.reload()
	_check(true, "publish and reload are no-ops off-web")
	_check(DotWeb.query_param_from("?a=1&b=two", "b") == "two" and DotWeb.query_param_from("", "b") == "", "query_param_from parses a search string")
	_check(DotWeb.query_param("press") == "" and DotWeb.pathname() == "", "page queries are empty off-web")
	var js := FileAccess.get_file_as_string("res://addons/dot_core/web/dot_web.js")
	_check(not js.is_empty() and not js.contains("eval(") and not js.contains("new Function("), "dot_web.js evaluates no string")
	print("%d passed, %d failed" % [_passed, _failed])
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected" % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
