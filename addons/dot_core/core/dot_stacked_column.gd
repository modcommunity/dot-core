class_name DotStackedColumn
extends RefCounted

## One column of a solid stacked chart, drawn into a [CanvasItem] from inside its `_draw`. The shared piece of the profiler's
## frame-cost graph and net_stat's channel graph, so both fill their bands the same way.


## Stacks [param heights] (pixels, band 0 at the bottom) from [param bottom], each in its [param colours] entry at [param alpha],
## [param width] wide, never taller than [param room] in all. Returns (pixels drawn, 1.0 when a band was cut off at the top).
static func draw(canvas: CanvasItem, x: float, bottom: float, width: float, heights: PackedFloat32Array,
		colours: Array[Color], room: float, alpha := 1.0) -> Vector2:
	var left := room
	var clipped := false
	for b in heights.size():
		var h := heights[b]
		if h <= 0.0:
			continue
		if h > left:
			h = left
			clipped = true
		if h <= 0.0:
			break
		var c := colours[b % colours.size()]
		canvas.draw_rect(Rect2(x, bottom - (room - left) - h, width, h), Color(c, c.a * alpha))
		left -= h
	return Vector2(room - left, 1.0 if clipped else 0.0)
