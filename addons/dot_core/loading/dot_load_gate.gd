class_name DotLoadGate
extends Node

## "The game is not ready to be seen yet": one node a game holds closed while its level,
## camera and players arrive, and that lifts a cover off the screen once they have.
##
## [codeblock]
## # In the client's root, _ready():
## gate = DotLoadGate.new()
## add_child(gate)                                   # child of the game's root
## gate.hold(&"map", "Loading the map")              # released when the level is built
## gate.require(&"player", func() -> bool: return player != null, "Joining")
## gate.freeze(player)                               # never simulates on a half-built world
## # Released: the frozen player settles onto the floor for a few physics frames, still
## # covered and with its input off, and only then is the game shown.
## # ...later, when the level is in:
## gate.release(&"map")
## # A map change: hold again; the cover comes back and the frozen nodes stop again.
## [/codeblock]
##
## [b]Why it exists.[/b] A delivered game is put on screen the moment its scene is added, and
## its map, its camera and its players arrive over the next second or more: without a cover
## the player watches a half-built world, a body falling through floor that is not there
## yet, and every material compiling at first sight. The shell had a cover for the one game
## that knew its duck-typed contract; this makes the same thing one line for every game, in
## the shell and outside it ([code]./game.sh play[/code], a standalone run).
##
## [b]Who covers.[/b] A host (the client shell) claims the job by putting
## [constant HOST_META] on an ancestor of the gate: the gate then calls the host's
## [code]adopt_load_gate(gate)[/code] when it enters the tree, shows nothing itself, and
## waits in [constant State.WARMING] for the host's [method host_finished] after
## [signal ready_to_show]. With no host the gate shows its own [DotLoadingCover] (or
## [member cover], [member cover_scene], [method _make_cover]) and runs [DotRenderWarmup]
## under it before lifting it.
##
## [b]Finding it.[/b] The gate puts [constant META] on its parent, so [method of] finds it
## from any node under the game; it also registers as [constant SERVICE] (scoped by
## [member service_scope]), last-wins like every registry service. Nothing is global: two
## clients in one process each have their own.
##
## [b]Older shells.[/b] A shell that predates the gate looks for a
## [code]ready_to_show[/code] signal on the game's root. The gate adds that signal to its
## parent as a user signal (unless the root declares its own) and emits it when it opens,
## so an older shell still covers until then.

const CHANNEL := "dot.load_gate"

## The [DotRegistry] name.
const SERVICE := &"dot_load_gate"
## Metadata the gate puts on its parent, read by [method of].
const META := &"dot_load_gate"
## Metadata a host puts on an ancestor to claim the covering job. Its value is an Object
## with [code]adopt_load_gate(gate)[/code].
const HOST_META := &"dot_load_gate_host"
## The reason [member require_camera] holds under.
const REASON_CAMERA := &"camera"
## The reason the gate holds under while waiting for a host or a warmup; never released by
## a game.
const REASON_SETTLE := &"settle"
## Metadata on each frozen node while it settles (simulating, still covered, input off). A
## node that reads input itself can check it, or ask the gate's [method is_settling].
const SETTLING_META := &"dot_load_gate_settling"

enum State {
	CLOSED,   ## Something is held: covered, frozen nodes stopped.
	WARMING,  ## Nothing is held: materials are drawn once under the cover.
	OPEN,     ## Shown.
}

## Nothing is held any more; the warm-up under the cover starts now. A host warms and then
## calls [method host_finished].
signal ready_to_show()
## The cover has lifted and frozen nodes run again.
signal opened()
## Closed again after having been open (a map change). Not emitted for the initial state,
## which is closed.
signal closed()
## The status line or the fraction changed. [param fraction] is -1 for "no fraction".
signal progress_changed(fraction: float, text: String)

## Seconds after which the gate opens anyway, with a warning naming what was still held: a
## game that never releases must not leave the player behind a picture. Counted from each
## closing.
@export var timeout_sec: float = 20.0

## Hold until a current camera (3D or 2D) inside the game exists. A game with no camera of
## its own turns this off.
@export var require_camera: bool = true

## Physics frames to wait once nothing is held, so bodies land on collision that has just
## been built before the cover lifts.
@export var settle_physics_frames: int = 3

## The most physics frames the frozen nodes run for, still covered, before the gate warms
## and opens: a body frozen in the air drops onto the floor here and not in front of the
## player. Their input is off meanwhile (see [method is_settling]). 30 because a 1 m drop
## takes 27 frames at 60 Hz; [member settle_until_rest] ends it after two for a body already
## standing. 0 skips settling: frozen nodes then start the moment the gate opens.
@export var settle_frames: int = 30

## End settling early, after two frames, once every frozen body is at rest: on the floor
## (when it has [code]is_on_floor()[/code]) and slower than [member settle_rest_speed]
## (its [code]velocity[/code] or [code]linear_velocity[/code]). Asked by name, so any body
## type answers.
@export var settle_until_rest: bool = true

## Metres per second under which a settling body counts as at rest.
@export var settle_rest_speed: float = 0.5

## Run [DotRenderWarmup] under the gate's own cover before lifting it (no host only).
@export var warm_up_on_open: bool = true

## The warm-up's own cap. A headless run never draws, so this is what ends it there.
@export var warm_timeout_sec: float = 5.0

## Seconds a host has, after [signal ready_to_show], to call [method host_finished].
@export var host_wait_sec: float = 10.0

## Register as [constant SERVICE]. Off for a gate that must not replace another's entry.
@export var register_service: bool = true

## Registers as [code]dot_load_gate#scope[/code] instead when set.
@export var service_scope: StringName = &""

## The status line when nothing held says anything.
@export var default_text: String = "Loading"

## A scene to instance as the cover instead of [DotLoadingCover]. See [method _make_cover].
@export var cover_scene: PackedScene = null

## The cover, assignable before it is first needed. Anything with [code]show_cover()[/code],
## [code]hide_cover()[/code], [code]set_status(text)[/code] and
## [code]set_progress(fraction)[/code]; [DotLoadingCover] is the stock one.
var cover: Node = null

## The node whose subtree [member require_camera] looks in, and that [method collect_warm_items]
## collects from. The parent when unset.
var game_root: Node = null

var _state: State = State.CLOSED
## reason -> text
var _holds: Dictionary = {}
## reason -> [Callable, text]
var _requires: Dictionary = {}
## Insertion order of reasons, for "the newest says what is happening".
var _order: Array[StringName] = []
## instance id -> {"ref": WeakRef, "mode": int, "frozen": bool}
var _frozen: Dictionary = {}
var _warm_extra: Array = []
var _fraction: float = -1.0
var _progress_text: String = ""
var _last_text: String = ""
var _host: Object = null
var _closed_msec: int = 0
var _settled: int = 0
var _host_wait_msec: int = 0
var _warmup: Node = null
var _timed_out: Array[StringName] = []
var _added_user_signal := false
var _registered_as: StringName = &""
var _cover_made := false
var _settling := false
var _settle_done := false
var _settle_ran := 0
## instance id -> {"ref", "input", "unhandled", "key", "shortcut", "enabled"}: what settling
## turned off, restored when the gate opens.
var _input_held: Dictionary = {}


func _init() -> void:
	# The gate must keep counting under a paused tree and over the nodes it froze.
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "LoadGate"


## The gate for [param node]: the nearest one on [param node] or an ancestor, else the
## registered one, else null.
static func of(node: Node) -> DotLoadGate:
	var n := node
	while n != null:
		if n.has_meta(META):
			var g: Variant = n.get_meta(META)
			if g is Object and is_instance_valid(g):
				return g
		n = n.get_parent()
	var s: Variant = DotRegistry.get_service(SERVICE)
	if s is Node and (s as Node).has_method(&"is_open"):
		return s
	return null


func _enter_tree() -> void:
	var parent := get_parent()
	if game_root == null:
		game_root = parent
	if parent != null:
		parent.set_meta(META, self)
		# An older shell watches the root for this signal; see the class description.
		if not parent.has_signal(&"ready_to_show"):
			parent.add_user_signal("ready_to_show")
			_added_user_signal = true
	if register_service:
		_registered_as = SERVICE if service_scope == &"" else DotRegistry.scoped_name(SERVICE, service_scope)
		DotRegistry.register(_registered_as, self)
	if _host == null:
		var host := _find_host()
		if host != null:
			hosted_by(host)
	if _closed_msec == 0:
		_closed_msec = Time.get_ticks_msec()


func _ready() -> void:
	if require_camera and not _holds.has(REASON_CAMERA) and not _requires.has(REASON_CAMERA):
		require(REASON_CAMERA, _has_camera)
	_freeze_all()
	if _state == State.CLOSED and _host == null:
		_show_own_cover()
	DotLog.debug(CHANNEL, "closed until the game is ready", {"hosted": _host != null})


func _exit_tree() -> void:
	var parent := get_parent()
	if parent != null and parent.has_meta(META) and parent.get_meta(META) == self:
		parent.remove_meta(META)
	if _registered_as != &"":
		DotRegistry.unregister_instance(_registered_as, self)
		_registered_as = &""
	# Leaving the tree must never leave a body frozen, or its input off.
	_settling = false
	_restore_all()
	_release_input()


func _find_host() -> Object:
	var n := get_parent()
	while n != null:
		if n.has_meta(HOST_META):
			var h: Variant = n.get_meta(HOST_META)
			if h is Object and is_instance_valid(h):
				return h
		n = n.get_parent()
	return null


# --- What a game calls ------------------------------------------------------------------

## Keeps the gate closed until [method release] with the same [param reason]. Holding
## while open closes it again: the cover returns and frozen nodes stop.
func hold(reason: StringName, text: String = "") -> void:
	_holds[reason] = text
	_touch(reason)
	DotLog.debug(CHANNEL, "held", {"reason": String(reason), "text": text})
	_close()
	_emit_progress()


## Lets go of [param reason]. Unknown reasons are ignored.
func release(reason: StringName) -> void:
	var had := _holds.erase(reason)
	had = _requires.erase(reason) or had
	if had:
		_order.erase(reason)
		DotLog.debug(CHANNEL, "released", {"reason": String(reason)})
		_emit_progress()


## Holds [param reason] until [param predicate] returns true, asked every frame. A
## predicate whose object was freed counts as true.
func require(reason: StringName, predicate: Callable, text: String = "") -> void:
	_requires[reason] = [predicate, text]
	_touch(reason)
	_close()
	_emit_progress()


## True while [param reason] is held or required.
func is_holding(reason: StringName) -> bool:
	return _holds.has(reason) or _requires.has(reason)


## Every reason still held or required, oldest first.
func reasons() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(_order)
	return out


func is_open() -> bool:
	return _state == State.OPEN


func state() -> State:
	return _state


## The fraction (0..1, or -1 for none) and the status line a cover shows. A [param text]
## of "" keeps the line the holds give.
func set_progress(fraction: float, text: String = "") -> void:
	_fraction = fraction
	_progress_text = text
	_emit_progress()


## What the cover says now: the progress text, else the newest hold's, else
## [member default_text].
func status_text() -> String:
	if _progress_text != "":
		return _progress_text
	for i in range(_order.size() - 1, -1, -1):
		var r: StringName = _order[i]
		var t := ""
		if _holds.has(r):
			t = str(_holds[r])
		elif _requires.has(r):
			t = str((_requires[r] as Array)[1])
		if t != "":
			return t
	return default_text


func progress() -> float:
	return _fraction


## Materials and meshes to draw once under the cover besides what is in the tree when it
## opens: weapons, effects, other players' models.
func warm_up(items: Array) -> void:
	for item: Variant in items:
		if item != null and not _warm_extra.has(item):
			_warm_extra.append(item)


## What [method warm_up] collected.
func warm_items() -> Array:
	return _warm_extra.duplicate()


## Everything to warm: [member game_root]'s materials and meshes plus [method warm_items].
func collect_warm_items() -> Array:
	var out: Array = DotRenderWarmup.collect(game_root) if game_root != null else []
	for item: Variant in _warm_extra:
		if not out.has(item):
			out.append(item)
	return out


## Stops [param node] (process_mode disabled) while the gate is closed, now and after each
## re-close, and restores its own process_mode when it opens. Freed nodes are forgotten.
func freeze(node: Node) -> void:
	if node == null:
		return
	var id := node.get_instance_id()
	if not _frozen.has(id):
		_frozen[id] = {"ref": weakref(node), "mode": node.process_mode, "frozen": false}
	if _settling:
		_hold_input(node)
	elif _state != State.OPEN:
		_freeze_one(_frozen[id])


## Like [method freeze], but the node stays stopped through settling as well, until the gate
## opens: for a node that reads input on its own (a sampler, a camera rig) and has no
## [code]input_enabled[/code] for settling to turn off.
func freeze_input(node: Node) -> void:
	if node == null:
		return
	freeze(node)
	var entry: Dictionary = _frozen[node.get_instance_id()]
	entry["through_settle"] = true
	if _state != State.OPEN:
		_freeze_one(entry)


## True while the frozen nodes run under the cover with their input off. Code that reads
## input itself and is not frozen with [method freeze_input] checks this (or
## [method is_open], which stays false until settling and the warm-up are over).
func is_settling() -> bool:
	return _settling
## Forgets [param node], restoring it first if it is stopped.
func unfreeze(node: Node) -> void:
	if node == null:
		return
	var id := node.get_instance_id()
	if _frozen.has(id):
		_restore_one(_frozen[id])
		_frozen.erase(id)
		_release_input_of(id)


# --- What a host calls ------------------------------------------------------------------

## [param host] covers the screen from now on: the gate's own cover goes, and a warm-up is
## the host's (see [method host_finished]).
func hosted_by(host: Object) -> void:
	_host = host
	_hide_own_cover()
	if host != null and host.has_method(&"adopt_load_gate"):
		host.call(&"adopt_load_gate", self)


func is_hosted() -> bool:
	return _host != null and is_instance_valid(_host)


## The host has warmed and lifted its cover: open.
func host_finished() -> void:
	if _state == State.WARMING:
		_open()


# --- The machine ------------------------------------------------------------------------

func _touch(reason: StringName) -> void:
	_order.erase(reason)
	_order.append(reason)


func _close() -> void:
	_settled = 0
	_settle_done = false
	if _state == State.CLOSED:
		if _settling:
			# Held again while settling: stop them again and settle afresh later.
			_settling = false
			_freeze_all()
		return
	var was_open := _state == State.OPEN
	_cancel_warmup()
	_state = State.CLOSED
	_closed_msec = Time.get_ticks_msec()
	if not is_inside_tree():
		return
	_freeze_all()
	if not is_hosted():
		_show_own_cover()
	if was_open:
		DotLog.debug(CHANNEL, "closed again", {"reasons": _reason_strings()})
		closed.emit()


func _process(_delta: float) -> void:
	match _state:
		State.CLOSED:
			_poll_requires()
			if not _order.is_empty() and Time.get_ticks_msec() - _closed_msec > int(timeout_sec * 1000.0):
				_timed_out.assign(_order)
				DotLog.warn(CHANNEL, "the game did not become ready in time; showing it anyway", {
					"seconds": timeout_sec, "still_held": _reason_strings(),
				})
				_holds.clear()
				_requires.clear()
				_order.clear()
				_emit_progress()
			if _order.is_empty() and _settled >= settle_physics_frames and not _settling:
				if _settle_done or settle_frames <= 0 or not _begin_settle():
					_begin_warming()
		State.WARMING:
			if not is_hosted() and _warmup == null:
				_open()  # the host went away mid-warm-up
			elif is_hosted() and Time.get_ticks_msec() - _host_wait_msec > int(host_wait_sec * 1000.0):
				DotLog.warn(CHANNEL, "the host did not finish its warm-up in time; opening", {"seconds": host_wait_sec})
				_open()


func _physics_process(_delta: float) -> void:
	if _state != State.CLOSED:
		return
	if not _order.is_empty():
		_settled = 0
	elif _settling:
		_settle_ran += 1
		var rest := settle_until_rest and _settle_ran >= 2 and _bodies_at_rest()
		if _settle_ran >= settle_frames or rest:
			_settling = false
			_settle_done = true
			DotLog.debug(CHANNEL, "settled", {"frames": _settle_ran, "at_rest": rest})
	else:
		_settled += 1


## Restores the frozen nodes' processing with their input off. False when there is nothing
## to settle.
func _begin_settle() -> bool:
	var any := false
	for id: int in _frozen.keys():
		var entry: Dictionary = _frozen[id]
		var node := (entry["ref"] as WeakRef).get_ref() as Node
		if node == null:
			_frozen.erase(id)
			continue
		if bool(entry.get("through_settle", false)):
			continue
		_hold_input(node)
		_restore_one(entry)
		any = true
	if not any:
		return false
	_settling = true
	_settle_ran = 0
	DotLog.debug(CHANNEL, "settling the frozen nodes under the cover", {"frames": settle_frames})
	return true


func _bodies_at_rest() -> bool:
	for id: int in _frozen:
		var entry: Dictionary = _frozen[id]
		if bool(entry.get("through_settle", false)):
			continue
		var node := (entry["ref"] as WeakRef).get_ref() as Node
		if node == null:
			continue
		if node.has_method(&"is_on_floor") and not bool(node.call(&"is_on_floor")):
			return false
		var v: Variant = null
		if &"velocity" in node:
			v = node.get(&"velocity")
		elif &"linear_velocity" in node:
			v = node.get(&"linear_velocity")
		if (v is Vector3 or v is Vector2) and v.length() > settle_rest_speed:
			return false
	return true


## Turns input off on [param node] and everything under it: event callbacks
## (set_process_input and the rest) and an [code]input_enabled[/code] property, which is
## how a dot-player-controller controller keeps simulating (falling, sliding to a stop)
## with every input released. Remembers each so the gate opening puts it back.
func _hold_input(node: Node) -> void:
	node.set_meta(SETTLING_META, true)
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var id := n.get_instance_id()
		if _input_held.has(id):
			continue
		var rec := {
			"ref": weakref(n), "root": n == node,
			"input": n.is_processing_input(), "unhandled": n.is_processing_unhandled_input(),
			"key": n.is_processing_unhandled_key_input(), "shortcut": n.is_processing_shortcut_input(),
			"enabled": null,
		}
		if &"input_enabled" in n and n.get(&"input_enabled") is bool:
			rec["enabled"] = n.get(&"input_enabled")
			n.set(&"input_enabled", false)
		n.set_process_input(false)
		n.set_process_unhandled_input(false)
		n.set_process_unhandled_key_input(false)
		n.set_process_shortcut_input(false)
		_input_held[id] = rec


func _release_input() -> void:
	for id: int in _input_held.keys():
		_release_input_of(id)


func _release_input_of(id: int) -> void:
	if not _input_held.has(id):
		return
	var rec: Dictionary = _input_held[id]
	_input_held.erase(id)
	var n := (rec["ref"] as WeakRef).get_ref() as Node
	if n == null:
		return
	n.set_process_input(bool(rec["input"]))
	n.set_process_unhandled_input(bool(rec["unhandled"]))
	n.set_process_unhandled_key_input(bool(rec["key"]))
	n.set_process_shortcut_input(bool(rec["shortcut"]))
	if rec["enabled"] != null:
		n.set(&"input_enabled", rec["enabled"])
	if bool(rec["root"]) and n.has_meta(SETTLING_META):
		n.remove_meta(SETTLING_META)


func _poll_requires() -> void:
	for reason: StringName in _requires.keys():
		var fn: Callable = (_requires[reason] as Array)[0]
		var done := true
		if fn.is_valid():
			done = bool(fn.call())
		if done:
			_requires.erase(reason)
			_order.erase(reason)
			DotLog.debug(CHANNEL, "requirement met", {"reason": String(reason)})
			_emit_progress()


func _has_camera() -> bool:
	if not is_inside_tree():
		return false
	var vp := get_viewport()
	var root := game_root if game_root != null else get_parent()
	if root == null:
		return false
	var c3 := vp.get_camera_3d()
	if c3 != null and (root == c3 or root.is_ancestor_of(c3)):
		return true
	var c2 := vp.get_camera_2d()
	return c2 != null and (root == c2 or root.is_ancestor_of(c2))


func _begin_warming() -> void:
	_state = State.WARMING
	_host_wait_msec = Time.get_ticks_msec()
	ready_to_show.emit()
	if _state != State.WARMING:
		return  # a listener held again
	if is_hosted():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if not warm_up_on_open or cam == null:
		_open()
		return
	var warm := DotRenderWarmup.new()
	warm.name = "LoadGateWarmup"
	warm.timeout_sec = warm_timeout_sec
	# The camera is often under a frozen body, and a disabled warm-up never times out.
	warm.process_mode = Node.PROCESS_MODE_ALWAYS
	warm.add_items(collect_warm_items())
	_warmup = warm
	var _c := warm.finished.connect(_on_own_warm_finished.bind(warm, Time.get_ticks_msec()))
	cam.add_child(warm)
	warm.start()


func _on_own_warm_finished(count: int, warm: Node, started: int) -> void:
	if warm != _warmup:
		return
	_warmup = null
	DotLog.debug(CHANNEL, "drew the game's materials once under the cover", {"items": count, "ms": Time.get_ticks_msec() - started})
	if _state == State.WARMING:
		_open()


func _cancel_warmup() -> void:
	if _warmup != null and is_instance_valid(_warmup):
		_warmup.queue_free()
	_warmup = null


func _open() -> void:
	_state = State.OPEN
	_settling = false
	_restore_all()
	_release_input()
	_hide_own_cover()
	_progress_text = ""
	_fraction = -1.0
	DotLog.info(CHANNEL, "the game is ready to be seen", {
		"ms": Time.get_ticks_msec() - _closed_msec, "hosted": is_hosted(),
		"timed_out": _timed_out.map(func(r: StringName) -> String: return String(r)),
	})
	_timed_out.clear()
	opened.emit()
	var parent := get_parent()
	if _added_user_signal and parent != null and parent.has_signal(&"ready_to_show"):
		parent.emit_signal(&"ready_to_show")


func _freeze_all() -> void:
	for id: int in _frozen.keys():
		if not _freeze_one(_frozen[id]):
			_frozen.erase(id)


func _restore_all() -> void:
	for id: int in _frozen.keys():
		if not _restore_one(_frozen[id]):
			_frozen.erase(id)


## False when the node is gone.
func _freeze_one(entry: Dictionary) -> bool:
	var node := (entry["ref"] as WeakRef).get_ref() as Node
	if node == null:
		return false
	if not bool(entry["frozen"]):
		entry["mode"] = node.process_mode
		entry["frozen"] = true
		node.process_mode = Node.PROCESS_MODE_DISABLED
	return true


func _restore_one(entry: Dictionary) -> bool:
	var node := (entry["ref"] as WeakRef).get_ref() as Node
	if node == null:
		return false
	if bool(entry["frozen"]):
		entry["frozen"] = false
		node.process_mode = int(entry["mode"]) as Node.ProcessMode
	return true


func _emit_progress() -> void:
	var text := status_text()
	if is_instance_valid(cover) and _cover_made:
		cover.call(&"set_status", text)
		cover.call(&"set_progress", _fraction)
	_last_text = text
	progress_changed.emit(_fraction, text)


# --- The gate's own cover ---------------------------------------------------------------

## The cover the gate shows when no host does. Override to build your own; the default is
## [member cover] if assigned, else an instance of [member cover_scene], else a
## [DotLoadingCover].
func _make_cover() -> Node:
	if cover != null:
		return cover
	if cover_scene != null:
		return cover_scene.instantiate()
	return DotLoadingCover.new()


func _show_own_cover() -> void:
	if not is_inside_tree():
		return
	if not _cover_made or not is_instance_valid(cover):
		cover = _make_cover()
		_cover_made = cover != null
		if cover != null and cover.get_parent() == null:
			add_child(cover)
	if cover != null:
		cover.call(&"show_cover")
		cover.call(&"set_status", status_text())
		cover.call(&"set_progress", _fraction)


func _hide_own_cover() -> void:
	if _cover_made and is_instance_valid(cover):
		cover.call(&"hide_cover")


## True while the gate's own cover is on screen.
func is_cover_showing() -> bool:
	return _cover_made and is_instance_valid(cover) and cover.has_method(&"is_showing") and bool(cover.call(&"is_showing"))


func _reason_strings() -> Array:
	return _order.map(func(r: StringName) -> String: return String(r))


func describe() -> Dictionary:
	var frozen := 0
	for id: int in _frozen:
		if bool((_frozen[id] as Dictionary)["frozen"]):
			frozen += 1
	return {
		"state": State.keys()[_state], "hosted": is_hosted(), "reasons": _reason_strings(),
		"text": status_text(), "fraction": _fraction, "frozen": frozen, "watched": _frozen.size(),
		"warm_extra": _warm_extra.size(), "closed_for_ms": Time.get_ticks_msec() - _closed_msec,
		"cover": is_cover_showing(), "settling": _settling, "input_held": _input_held.size(),
	}


func describe_lines() -> PackedStringArray:
	var d := describe()
	var out := PackedStringArray()
	out.append("load gate: %s%s%s" % [d["state"], " settling" if d["settling"] else "", " (hosted)" if d["hosted"] else ""])
	out.append("  held: %s" % (", ".join(PackedStringArray(d["reasons"])) if not (d["reasons"] as Array).is_empty() else "nothing"))
	out.append("  says: %s (%s)" % [d["text"], "no fraction" if float(d["fraction"]) < 0.0 else "%d%%" % int(float(d["fraction"]) * 100.0)])
	out.append("  frozen: %d of %d watched" % [d["frozen"], d["watched"]])
	return out
