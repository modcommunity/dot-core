extends CharacterBody3D

## A body that falls, for load_gate_selftest's settle section: it reads "input" only while
## [member input_enabled], as a dot-player-controller controller does, and counts events.

var input_enabled := true
var input_ticks := 0
var events := 0
var ticks := 0


func _physics_process(delta: float) -> void:
	ticks += 1
	if input_enabled:
		input_ticks += 1
	velocity.y -= 9.8 * delta
	move_and_slide()


func _unhandled_input(_event: InputEvent) -> void:
	events += 1
