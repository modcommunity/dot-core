class_name DotLoadingCover
extends CanvasLayer

## The plain cover a [DotLoadGate] shows when nothing else covers the screen: a dark full
## screen, a status line and a progress bar (indeterminate when there is no fraction).
##
## [b]Swapping it.[/b] Subclass this and override [method _build] (or the four methods), or
## give the gate any node with [code]show_cover()[/code], [code]hide_cover()[/code],
## [code]set_status(text)[/code] and [code]set_progress(fraction)[/code] through
## [member DotLoadGate.cover] or [member DotLoadGate.cover_scene]. A host such as a client
## shell claims the job instead and this is never built.
##
## It shows at full opacity in the frame it is asked to, never fading in: what it covers has
## just been put on screen, and a fade is a quarter of a second of that.

## Above every game's own UI layers.
const LAYER := 120

@export var background := Color(0.06, 0.07, 0.09, 1.0)
@export var text_color := Color(0.85, 0.88, 0.92, 1.0)

var _root: Control = null
var _status: Label = null
var _bar: ProgressBar = null
var _showing := false


func _init() -> void:
	layer = LAYER
	name = "LoadingCover"
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	if _root == null:
		_build()
	visible = _showing


## Builds the view. Override for a different look; keep [member _status] and [member _bar]
## (or override [method set_status] and [method set_progress] too).
func _build() -> void:
	_root = ColorRect.new()
	(_root as ColorRect).color = background
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 12)
	_root.add_child(box)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", text_color)
	_status.add_theme_font_size_override("font_size", 20)
	box.add_child(_status)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(360, 8)
	_bar.show_percentage = false
	_bar.max_value = 100.0
	_bar.indeterminate = true
	box.add_child(_bar)


func show_cover() -> void:
	_showing = true
	visible = true


func hide_cover() -> void:
	_showing = false
	visible = false


func is_showing() -> bool:
	return _showing


func set_status(text: String) -> void:
	if _root == null:
		_build()
	_status.text = text


## 0..1, or negative for "no fraction" (the bar runs indeterminate).
func set_progress(fraction: float) -> void:
	if _root == null:
		_build()
	if fraction < 0.0:
		_bar.indeterminate = true
	else:
		_bar.indeterminate = false
		_bar.value = clampf(fraction, 0.0, 1.0) * 100.0


func status() -> String:
	return _status.text if _status != null else ""


func describe() -> Dictionary:
	return {
		"showing": _showing, "status": status(),
		"fraction": -1.0 if _bar == null or _bar.indeterminate else _bar.value / 100.0,
	}
