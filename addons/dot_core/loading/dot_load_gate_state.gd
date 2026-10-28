extends Node

## Constants, signals, settings and state behind [DotLoadGate]; use [DotLoadGate].

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
## Settling: a body whose position moved less than this (metres) in a physics frame is still.
const REST_EPSILON := 0.001
## Settling: consecutive still physics frames after which a body counts as at rest.
const REST_FRAMES := 3
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

## End settling early once every frozen body is at rest. A body is at rest when the engine
## says so (it has [code]is_on_floor()[/code], is on the floor, and is slower than
## [member settle_rest_speed] by its [code]velocity[/code] or [code]linear_velocity[/code]:
## two frames) OR when its [code]global_position[/code] has moved less than
## [constant REST_EPSILON] for [constant REST_FRAMES] physics frames in a row. The position
## test is the one that cannot be fooled: a body without [code]is_on_floor()[/code] or
## [code]velocity[/code] used to count as at rest at once, lifting the cover on a body still
## falling, and a [code]CharacterBody3D[/code] the game moves by script never reports a
## floor or a velocity that matches its motion, so it always ran the whole cap. A node with
## no position (a plain [Node]) is at rest. Asked by name, so any body type answers.
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
