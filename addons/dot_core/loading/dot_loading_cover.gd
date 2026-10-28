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
## Game name above the status line; empty builds no title.
@export var title := "":
	set(value):
		title = value
		_sync_text(0)
## Already-translated hint under the title; empty builds no tip.
@export var tip := "":
	set(value):
		tip = value
		_sync_text(1)
## Title colour; the default follows [member text_color].
@export var title_color := Color(0, 0, 0, 0)

var _root: Control = null
var _box: VBoxContainer = null
var _title: Label = null
var _tip: Label = null
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
	_box = box
	_sync_text(0)
	_sync_text(1)

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


## Creates, updates or hides the title (0) or tip (1) label; nothing is built while empty.
func _sync_text(which: int) -> void:
	if _box == null:
		return
	var text := title if which == 0 else tip
	var label := _title if which == 0 else _tip
	if label == null:
		if text.is_empty():
			return
		label = Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if which == 0:
			label.add_theme_font_size_override("font_size", 48)
			label.add_theme_color_override("font_color",
					title_color if title_color.a > 0.0 else text_color)
			_title = label
		else:
			label.add_theme_font_size_override("font_size", 16)
			label.add_theme_color_override("font_color", text_color.darkened(0.15))
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_tip = label
		_box.add_child(label)
		_box.move_child(label, 0 if which == 0 else (1 if _title != null else 0))
	label.text = text
	label.visible = not text.is_empty()


func set_title(text: String) -> void:
	title = text


func set_tip(text: String) -> void:
	tip = text


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
		"showing": _showing, "status": status(), "title": title, "tip": tip,
		"fraction": -1.0 if _bar == null or _bar.indeterminate else _bar.value / 100.0,
	}
