class_name DotCollisionAudit
extends RefCounted

## Lists the visible geometry under a node that nothing collides with, the level pieces a player
## walks through. Structural, so it needs no physics space and runs on a scene not in the tree.
## Covered: a solid body that is an ancestor, child or sibling with an enabled shape and a layer;
## a CSG root with [code]use_collision[/code]; a GridMap item with shapes. Areas never cover.
## Skipped: invisible, shadow-only, under a character or rigid body, or [code]dot_no_collision[/code]
## (metadata or group, inherited by a subtree).

const META := &"dot_no_collision"
const GROUP := &"dot_no_collision"

## One finding is {path: NodePath (relative to the audited root), kind: String, why: String}.
var findings: Array[Dictionary] = []
## How many drawable nodes were examined, covered or not: a report of 0 findings over 0
## examined is an empty scene, not a clean one.
var examined := 0
## How many were skipped by an opt-out.
var opted_out := 0

## Root-space bounds of every blocking shape, when auditing with [code]anywhere[/code]; null otherwise.
var _shape_bounds: Variant = null


## Audit [param root] and everything under it; CODE_INVALID for a null or freed root.
## [param anywhere] also accepts a solid body anywhere under [param root] whose shape bounds meet
## the node's, for a level keeping drawing and collision in separate subtrees. Lenient by design.
static func audit(root: Node, anywhere := false) -> DotResult:
	if root == null or not is_instance_valid(root):
		return DotResult.failure(DotError.make(DotError.CODE_INVALID, "DotCollisionAudit.audit: no root node"))
	var report := DotCollisionAudit.new()
	if anywhere:
		report._shape_bounds = []
		report._collect_bounds(root, root)
	report._walk(root, root, false)
	return DotResult.success(report)


## True when [param node] is opted out directly (not through an ancestor).
static func is_opted_out(node: Node) -> bool:
	if node.has_meta(META) and node.get_meta(META) == true:
		return true
	return node.is_in_group(GROUP)


func count() -> int:
	return findings.size()


## The paths only, for a known-list comparison.
func paths() -> PackedStringArray:
	var out := PackedStringArray()
	for f in findings:
		out.append(str(f["path"]))
	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("collision audit: %d without collision of %d examined (%d opted out)" % [findings.size(), examined, opted_out])
	for f in findings:
		lines.append("  %s (%s): %s" % [f["path"], f["kind"], f["why"]])
	return lines


func _walk(node: Node, root: Node, opted: bool) -> void:
	if node is CharacterBody3D or node is RigidBody3D:
		return
	if node is Node3D and not (node as Node3D).visible:
		return
	if node is CanvasItem and not (node as CanvasItem).visible:
		return
	if not opted and is_opted_out(node):
		opted = true
	if opted:
		if _is_drawable(node):
			opted_out += 1
		# Descendants are opted out too, but keep walking only to count them.
		for child in node.get_children():
			_walk(child, root, true)
		return

	if node is CSGShape3D:
		# Only the root of a CSG tree is judged: its children are merged into it.
		var csg := node as CSGShape3D
		if not csg.is_root_shape():
			for child in node.get_children():
				_walk(child, root, false)
			return
		examined += 1
		if not csg.use_collision and not _covered_by_body(node):
			_add(root, node, "CSG", "use_collision is off and no body covers it")
	elif node is GridMap:
		examined += 1
		var why := _gridmap_gap(node as GridMap)
		if why != "" and not _covered_by_body(node):
			_add(root, node, "GridMap", why)
	elif node is MultiMeshInstance3D:
		var mm := (node as MultiMeshInstance3D).multimesh
		if mm != null and mm.instance_count > 0 and mm.mesh != null:
			examined += 1
			if not _covered_by_body(node):
				_add(root, node, "MultiMesh", "a MultiMesh has no collision of its own and no body covers it")
	elif node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null and mi.layers != 0 and mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			examined += 1
			if not _covered_by_body(node):
				_add(root, node, "Mesh", "no solid body with a shape covers it")

	for child in node.get_children():
		_walk(child, root, false)


func _is_drawable(node: Node) -> bool:
	return node is MeshInstance3D or node is CSGShape3D or node is GridMap or node is MultiMeshInstance3D


func _add(root: Node, node: Node, kind: String, why: String) -> void:
	findings.append({"path": root.get_path_to(node), "kind": kind, "why": why})


## A body around [param node] that really blocks: an ancestor, a child or a sibling. A sibling
## counts only when bounds meet, or in a flat level one body would cover every other box.
func _covered_by_body(node: Node) -> bool:
	if _shape_bounds != null and _covered_anywhere(node):
		return true
	var up := node.get_parent()
	while up != null:
		if _blocks(up):
			return true
		up = up.get_parent()
	for child in node.get_children():
		if _blocks(child):
			return true
	var parent := node.get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling != node and _blocks(sibling) and _overlaps(node, sibling):
				return true
	return false


func _covered_anywhere(node: Node) -> bool:
	if not node is VisualInstance3D:
		return false
	var box := _root_transform(node) * (node as VisualInstance3D).get_aabb()
	for b: AABB in _shape_bounds:
		if box.grow(0.1).intersects(b):
			return true
	return false


func _collect_bounds(node: Node, root: Node) -> void:
	if _blocks(node):
		var base := _root_transform(node)
		for child in node.get_children():
			if child is CollisionShape3D and not (child as CollisionShape3D).disabled and (child as CollisionShape3D).shape != null:
				var cs := child as CollisionShape3D
				var mesh := cs.shape.get_debug_mesh()
				if mesh != null:
					_shape_bounds.append(base * (cs.transform * mesh.get_aabb()))
	for child in node.get_children():
		_collect_bounds(child, root)


## [param node]'s transform composed up through every Node3D parent. Shapes and meshes are
## both taken this way, so the top of the chain is the same for both and cancels; a plain
## Node between two Node3Ds is stepped over.
static func _root_transform(node: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var up := node
	while up != null:
		if up is Node3D:
			t = (up as Node3D).transform * t
		up = up.get_parent()
	return t


## True when a sibling body's shapes and the node's bounds meet, compared in the parent's
## space (siblings share it, so no global transforms, and the audit works off the tree).
## A little slack, because a visual and its collision are rarely identical to the millimetre.
static func _overlaps(node: Node, body: Node) -> bool:
	var a := _local_bounds(node)
	if not node is Node3D:
		return true
	var slack := 0.1
	for child in body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			var cs := child as CollisionShape3D
			var mesh := cs.shape.get_debug_mesh()
			if mesh == null:
				return true
			var b := (body as Node3D).transform * (cs.transform * mesh.get_aabb())
			if a.grow(slack).intersects(b):
				return true
		elif child is CollisionPolygon3D:
			return true
	return false


static func _local_bounds(node: Node) -> AABB:
	var n3 := node as Node3D
	if n3 == null:
		return AABB()
	var box := AABB()
	if node is VisualInstance3D:
		box = (node as VisualInstance3D).get_aabb()
	return n3.transform * box


## A solid body with at least one enabled shape that sits on some collision layer.
static func _blocks(node: Node) -> bool:
	if not (node is StaticBody3D or node is AnimatableBody3D):
		return false
	if (node as CollisionObject3D).collision_layer == 0:
		return false
	for child in node.get_children():
		if child is CollisionShape3D:
			var cs := child as CollisionShape3D
			if not cs.disabled and cs.shape != null:
				return true
		elif child is CollisionPolygon3D:
			if not (child as CollisionPolygon3D).disabled:
				return true
	return false


## "" when the GridMap collides, otherwise the reason it does not.
static func _gridmap_gap(grid: GridMap) -> String:
	if grid.mesh_library == null:
		return ""
	if grid.collision_layer == 0:
		return "collision_layer is 0"
	var items := _used_items(grid)
	if items.is_empty():
		return ""
	for item in items:
		if not grid.mesh_library.get_item_shapes(item).is_empty():
			return ""
	return "no used mesh-library item has a collision shape"


static func _used_items(grid: GridMap) -> Array[int]:
	var seen := {}
	for cell in grid.get_used_cells():
		seen[grid.get_cell_item(cell)] = true
	var out: Array[int] = []
	for item in seen:
		out.append(int(item))
	return out
