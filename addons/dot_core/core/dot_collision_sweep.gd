class_name DotCollisionSweep
extends RefCounted

## Compares what a level draws with what its physics world collides with, by rays, and lists where they disagree.
##
## [codeblock]
## var sweep := DotCollisionSweep.new(space, mask)
## sweep.add_faces(&"world", faces)
## sweep.play = func(p: Vector3) -> bool: return my_floor_plan_has(p)
## sweep.sweep_drawn()                  # drawn floor and walls nothing collides with
## sweep.sweep_collision(standing_points) # collision nothing is drawn at (invisible walls)
## print(sweep.describe_lines())
## [/codeblock]
##
## [b]Why rays and not shapes.[/b] [DotCollisionAudit] asks whether a mesh has a body near it; a level made of
## a few hundred merged shapes and a drawn world beside them passes that while a staircase's treads sit
## a metre off the shapes that were meant to hold them. A ray down onto the drawn surface and out of the
## drawn wall asks what a player's capsule would ask.
## [br][b]Cells, not triangles[/b]: findings are counted per [constant CELL] of floor, so one missing room
## is one number however it was tessellated.

## Findings of one kind within this many metres of each other are one place.
const CELL := 2.0
## A drawn surface needs collision within this far above or below it (a step's height is the game's own).
var tolerance := 0.35
## Free height over a drawn floor for it to be somewhere a person stands.
var headroom := 1.8
## Spacing of samples over a drawn face, metres.
var step := 2.0
## Faces smaller than this are trim, not floor.
var min_area := 0.25
## Floor-like: the normal's y at or above this (a ray down is the test); a wall is anything below [member wall_normal_y] in magnitude.
var floor_normal_y := 0.5
var wall_normal_y := 0.5
## Returns whether a sample is somewhere that matters (in the floor plan); unset accepts everything.
var play: Callable = Callable()
## How far a horizontal ray reaches from a standing point when looking for collision that is not drawn.
var reach := 6.0
var examples_per_kind := 6

## Findings: kind -> {cells: Dictionary of Vector3i -> true, by: Dictionary of label -> count, examples: PackedStringArray}.
var results: Dictionary = {}
## How many drawn samples and standing-point rays were tried; a zero-finding report over zero samples is not clean.
var floor_samples := 0
var wall_samples := 0
var probe_rays := 0

var _space: PhysicsDirectSpaceState3D
var _mask := 0
var _faces: Dictionary = {}
var _all: PackedVector3Array = PackedVector3Array()
var _drawn: TriangleMesh = null


func _init(space: PhysicsDirectSpaceState3D, collision_mask: int) -> void:
	_space = space
	_mask = collision_mask


## Adds drawn triangles (world space, three vertices each) under [param tag], a label findings are counted by.
func add_faces(tag: StringName, faces: PackedVector3Array) -> void:
	if faces.is_empty():
		return
	var have: PackedVector3Array = _faces.get(tag, PackedVector3Array())
	have.append_array(faces)
	_faces[tag] = have
	_all.append_array(faces)
	_drawn = null


## Adds every visible mesh under [param root], in world space, under [param tag].
func add_node(tag: StringName, root: Node) -> void:
	var nodes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		nodes.append(root)
	for n in nodes:
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var xf := mi.global_transform if mi.is_inside_tree() else _chain(mi)
		var local := mi.mesh.get_faces()
		var out := PackedVector3Array()
		out.resize(local.size())
		for i in local.size():
			out[i] = xf * local[i]
		add_faces(tag, out)


## Drawn floor and walls (the tags in [param tags], every one when empty) with no collision within [member tolerance].
func sweep_drawn(tags: Array[StringName] = []) -> void:
	for tag: StringName in _faces:
		if not tags.is_empty() and not tag in tags:
			continue
		var faces: PackedVector3Array = _faces[tag]
		for t in range(0, faces.size() - 2, 3):
			_sample(tag, faces[t], faces[t + 1], faces[t + 2])


## Collision a person can walk into that nothing is drawn at: rays down and out from each of [param stands].
## [param label_of] names what was hit (by default its own name: Solid, Clip, WorldCollision...), so intended invisible walls can be told apart.
func sweep_collision(stands: PackedVector3Array, label_of: Callable = Callable()) -> void:
	var tree := _triangles()
	if tree == null:
		return
	for s in stands:
		var dirs: Array[Vector3] = [Vector3.DOWN]
		for k in 8:
			dirs.append(Vector3(cos(TAU * k / 8.0), 0.0, sin(TAU * k / 8.0)))
		for d in dirs:
			var from := s + (Vector3.UP * 0.9 if d != Vector3.DOWN else Vector3.UP * 0.3)
			var hit := _space.intersect_ray(_ray(from, from + d * (reach if d != Vector3.DOWN else 1.0)))
			probe_rays += 1
			if hit.is_empty():
				continue
			var at: Vector3 = hit["position"]
			var n: Vector3 = hit["normal"]
			# From the hit's own side, back into it: anything drawn within the tolerance answers.
			if not _drawn_within(tree, at + n * tolerance, -n, 2.0 * tolerance):
				var label: String = label_of.call(hit["collider"]) if label_of.is_valid() else _label(hit["collider"])
				_record("invisible_floor" if d == Vector3.DOWN else "invisible_wall", at, label, "")


## Failure when a sweep that ran sampled nothing (a world built with draw off has no meshes, so "0 findings" would be false comfort).
## [param need_floor] and [param need_wall] say which samples this level must have produced.
func verdict(need_floor: bool = true, need_wall: bool = false) -> DotResult:
	if need_floor and floor_samples == 0:
		return DotResult.fail(DotError.CODE_STATE, "the sweep sampled no drawn floor", "is the world built with draw on? %d wall samples, %d probe rays" % [wall_samples, probe_rays])
	if need_wall and wall_samples == 0:
		return DotResult.fail(DotError.CODE_STATE, "the sweep sampled no drawn wall", "%d floor samples, %d probe rays" % [floor_samples, probe_rays])
	return DotResult.success(results.size())


## Counts of cells per kind and label as lines, then examples.
func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%d floor samples, %d wall samples, %d probe rays" % [floor_samples, wall_samples, probe_rays])
	for kind: String in results:
		var r: Dictionary = results[kind]
		out.append("%s: %d places %s" % [kind, (r["cells"] as Dictionary).size(), r["by"]])
		for e: String in r["examples"]:
			out.append("    " + e)
	return out


## Places found of [param kind], optionally only those labelled [param label].
func count(kind: String, label: String = "") -> int:
	if not results.has(kind):
		return 0
	if label == "":
		return (results[kind]["cells"] as Dictionary).size()
	return int((results[kind]["by_cells"] as Dictionary).get(label, 0))


func _sample(tag: StringName, a: Vector3, b: Vector3, c: Vector3) -> void:
	# Godot's front faces are clockwise, so the cross product points away from the viewer.
	var n := (c - a).cross(b - a)
	var area := n.length() * 0.5
	if area < min_area:
		return
	n = n.normalized()
	var k := clampi(ceili(sqrt(area) / step), 1, 40)
	for i in k:
		for j in k - i:
			_point(tag, a + (b - a) * ((i + 1.0 / 3.0) / k) + (c - a) * ((j + 1.0 / 3.0) / k), n)
			if i + j < k - 1:
				_point(tag, a + (b - a) * ((i + 2.0 / 3.0) / k) + (c - a) * ((j + 2.0 / 3.0) / k), n)


func _point(tag: StringName, p: Vector3, n: Vector3) -> void:
	if n.y >= floor_normal_y:
		if play.is_valid() and not play.call(p):
			return
		var tree := _triangles()
		# Under a ceiling or inside a stand-in it is not somewhere anyone stands.
		if tree != null and _drawn_within(tree, p + Vector3.UP * 0.05, Vector3.UP, headroom):
			return
		floor_samples += 1
		var from := p + Vector3.UP * tolerance
		if not _space.intersect_ray(_ray(from, p - Vector3.UP * tolerance)).is_empty():
			return
		if _inside(p + Vector3.UP * 0.1):
			return
		var below := _space.intersect_ray(_ray(from, p - Vector3.UP * 4.0))
		var cause := "nothing"
		if not below.is_empty():
			var drop := p.y - (below["position"] as Vector3).y
			cause = "lower<1m" if drop < 1.0 else ("lower<3m" if drop < 3.0 else "lower>3m")
		_record("floor_missing", p, str(tag), cause)
	elif absf(n.y) < wall_normal_y:
		if play.is_valid() and not play.call(p):
			return
		wall_samples += 1
		var from := p + n * 0.3
		if not _space.intersect_ray(_ray(from, p - n * tolerance)).is_empty():
			return
		if _inside(p) or _inside(p - n * 0.1):
			return
		# Collision already in front of the wall (a shape thicker than the drawing) is the other sweep's invisible wall, not a gap.
		if _inside(from):
			_record("wall_buried", p, str(tag), "")
			return
		# Collision a little way behind the drawn wall is an offset shape; none at all is a wall to walk through.
		var behind := _space.intersect_ray(_ray(from, p - n * 3.0))
		var cause := "none"
		if not behind.is_empty():
			cause = "behind<1m" if from.distance_to(behind["position"]) < 1.3 else "behind<3m"
		_record("wall_missing", p, str(tag), cause)


func _record(kind: String, at: Vector3, label: String, cause: String) -> void:
	if not results.has(kind):
		results[kind] = {"cells": {}, "by": {}, "by_cells": {}, "examples": PackedStringArray()}
	var r: Dictionary = results[kind]
	var cell := Vector3i((at / CELL).floor())
	var key := "%s/%s" % [label, cause] if cause != "" else label
	if (r["cells"] as Dictionary).has(cell):
		return
	(r["cells"] as Dictionary)[cell] = true
	(r["by"] as Dictionary)[key] = int((r["by"] as Dictionary).get(key, 0)) + 1
	(r["by_cells"] as Dictionary)[label] = int((r["by_cells"] as Dictionary).get(label, 0)) + 1
	var shown: PackedStringArray = r["examples"]
	if shown.size() < examples_per_kind:
		shown.append("%s at (%.1f, %.1f, %.1f)" % [key, at.x, at.y, at.z])
		r["examples"] = shown


## TriangleMesh rays have no length: whether something drawn lies within [param length] along [param dir].
static func _drawn_within(tree: TriangleMesh, from: Vector3, dir: Vector3, length: float) -> bool:
	var hit := tree.intersect_ray(from, dir)
	return not hit.is_empty() and from.distance_to(hit["position"]) <= length


func _inside(p: Vector3) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = p
	q.collision_mask = _mask
	return not _space.intersect_point(q, 1).is_empty()


func _ray(from: Vector3, to: Vector3) -> PhysicsRayQueryParameters3D:
	return PhysicsRayQueryParameters3D.create(from, to, _mask)


func _triangles() -> TriangleMesh:
	if _drawn == null and not _all.is_empty():
		_drawn = TriangleMesh.new()
		_drawn.create_from_faces(_all)
	return _drawn


static func _label(collider: Object) -> String:
	return String((collider as Node).name) if collider is Node else "?"


static func _chain(n: Node3D) -> Transform3D:
	var xf := n.transform
	var p := n.get_parent() as Node3D
	while p != null:
		xf = p.transform * xf
		p = p.get_parent() as Node3D
	return xf
