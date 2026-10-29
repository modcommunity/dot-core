extends Node

## DotClipMetrics.pose_sample follows the leg the mesh deforms, not an IK control foot bone under the root.
## godot --headless --path . res://examples/clip_metrics_selftest.tscn

var _failed := 0


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _build(control: bool) -> Skeleton3D:
	var sk := Skeleton3D.new()
	sk.add_bone("Root")
	sk.add_bone("Hips")
	sk.add_bone("LowerLeg.L")
	sk.add_bone("Foot.L")
	sk.set_bone_parent(1, 0)
	sk.set_bone_parent(2, 1)
	sk.set_bone_parent(3, 0 if control else 2)
	sk.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 0.9, 0)))
	sk.set_bone_rest(2, Transform3D(Basis(), Vector3(0, -0.45, 0)))
	sk.set_bone_rest(3, Transform3D(Basis(), Vector3(0, 0.02, 0) if control else Vector3(0, -0.43, 0)))
	sk.reset_bone_poses()
	return sk


func _ready() -> void:
	for control in [true, false]:
		var sk := _build(control)
		add_child(sk)
		var m := DotClipMetrics.new()
		var rest: Dictionary = m.pose_sample(0.0, sk, Vector3.ZERO, true)
		sk.set_bone_pose_position(1, Vector3(0, 0.8, 0))
		sk.set_bone_pose_position(3, sk.get_bone_pose_position(3) + Vector3(0, -0.3, 0)) if control else null
		var low: Dictionary = m.pose_sample(0.1, sk, Vector3.ZERO, true)
		var drop: float = (rest["feet"][0] as Vector3).y - (low["feet"][0] as Vector3).y
		# Hips drop 0.1: a leg-driven ankle falls 0.1 whatever the control bone does.
		_check(absf(drop - 0.1) < 0.001, "%s foot: ankle follows the leg (fell %.3f)" % ["control" if control else "child", drop])
		sk.queue_free()
	print("clip_metrics_selftest: %d failed" % _failed)
	get_tree().quit(1 if _failed > 0 else 0)
