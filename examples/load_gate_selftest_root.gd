extends Node

## A game root that declares the older shells' contract itself, for load_gate_selftest.

signal ready_to_show()

var emitted := 0


func _ready() -> void:
	ready_to_show.connect(func() -> void: emitted += 1)
