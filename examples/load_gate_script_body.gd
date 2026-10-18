extends CharacterBody3D

## A CharacterBody3D the game moves by script and never through move_and_slide(), for
## load_gate_selftest: is_on_floor() is always false and velocity says nothing about motion.
## It lowers itself until y = 0.

func _physics_process(_delta: float) -> void:
	if position.y > 0.0:
		position.y = maxf(0.0, position.y - 0.05)
