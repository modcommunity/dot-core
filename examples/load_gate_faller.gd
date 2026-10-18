extends Node3D

## A body with no is_on_floor() and no velocity, for load_gate_selftest: it lowers itself
## by script until it reaches y = 0 and stays there, as a tween- or script-driven body does.

var ticks := 0


func _physics_process(_delta: float) -> void:
	ticks += 1
	if position.y > 0.0:
		position.y = maxf(0.0, position.y - 0.05)
