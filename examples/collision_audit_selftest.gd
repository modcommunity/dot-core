extends Node

## Exercises [DotCollisionAudit] on hand-built trees: what it must report, what it must not,
## and the opt-out. Structural, so no physics space is needed.
##
## [codeblock]
## godot --headless --path . res://examples/collision_audit_selftest.tscn
## [/codeblock]

const SECTIONS := 8
const CHECKS := 30

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_line("dot-core collision audit self-test")
	_test_meshes()
	_test_bodies_that_do_not_cover()
	_test_csg()
	_test_multimesh_gridmap()
	_test_skipped()
	_test_opt_out()
	_test_anywhere()
	_test_report()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		_line("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _mesh(name: String) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = name
	m.mesh = BoxMesh.new()
	return m


func _body(name: String, shaped := true) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = name
	if shaped:
		var cs := CollisionShape3D.new()
		cs.shape = BoxShape3D.new()
		b.add_child(cs)
	return b


func _found(root: Node) -> PackedStringArray:
	var res := DotCollisionAudit.audit(root)
	return res.value.paths() if res.ok else PackedStringArray(["<failed>"])


func _has(root: Node, path: String) -> bool:
	return _found(root).has(path)


func _test_meshes() -> void:
	_section("Meshes: bare is reported, covered is not")
	var root := Node3D.new()
	var bare := _mesh("Bare")
	bare.position = Vector3(50, 0, 0)
	root.add_child(bare)
	var under := _body("Under")
	under.add_child(_mesh("Inside"))
	root.add_child(under)
	var pair := Node3D.new()
	pair.name = "Pair"
	pair.add_child(_mesh("Visual"))
	pair.add_child(_body("Body"))
	root.add_child(pair)
	var own := _mesh("Trimesh")
	own.add_child(_body("Body"))
	root.add_child(own)
	_check(_has(root, "Bare"), "a mesh with nothing around it is reported")
	_check(not _has(root, "Under/Inside"), "a mesh under a body with a shape is covered")
	var far := Node3D.new()
	far.name = "Far"
	far.add_child(_mesh("Visual"))
	var far_body := _body("Body")
	far_body.position = Vector3(30, 0, 0)
	far.add_child(far_body)
	root.add_child(far)
	_check(_has(root, "Far/Visual"), "a sibling body far from the mesh does not cover it")
	_check(not _has(root, "Pair/Visual"), "a mesh with a sibling body is covered")
	_check(not _has(root, "Trimesh"), "a mesh with a child body is covered")
	_check(_found(root).size() == 2, "and nothing else in the tree is")
	root.free()


func _test_bodies_that_do_not_cover() -> void:
	_section("Bodies that block nothing do not cover")
	var root := Node3D.new()
	var empty := _body("Empty", false)
	empty.add_child(_mesh("A"))
	root.add_child(empty)
	var off := _body("Off")
	(off.get_child(0) as CollisionShape3D).disabled = true
	off.add_child(_mesh("B"))
	root.add_child(off)
	var layerless := _body("Layerless")
	layerless.collision_layer = 0
	layerless.add_child(_mesh("C"))
	root.add_child(layerless)
	var area := Area3D.new()
	area.name = "Zone"
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	area.add_child(cs)
	area.add_child(_mesh("D"))
	root.add_child(area)
	_check(_has(root, "Empty/A"), "a body with no shape does not cover")
	_check(_has(root, "Off/B"), "a body with only a disabled shape does not cover")
	_check(_has(root, "Layerless/C"), "a body on no layer does not cover")
	_check(_has(root, "Zone/D"), "an Area3D does not cover")
	root.free()


func _test_csg() -> void:
	_section("CSG: the root's use_collision decides, children are not reported")
	var root := Node3D.new()
	var solid := CSGBox3D.new()
	solid.name = "Solid"
	solid.use_collision = true
	var cut := CSGBox3D.new()
	cut.name = "Cut"
	cut.operation = CSGShape3D.OPERATION_SUBTRACTION
	solid.add_child(cut)
	root.add_child(solid)
	var ghost := CSGBox3D.new()
	ghost.name = "Ghost"
	var bit := CSGBox3D.new()
	bit.name = "Bit"
	ghost.add_child(bit)
	root.add_child(ghost)
	_check(not _has(root, "Solid"), "a CSG root with use_collision is covered")
	_check(not _has(root, "Solid/Cut"), "its child is not reported")
	_check(_has(root, "Ghost"), "a CSG root without use_collision is reported")
	_check(not _has(root, "Ghost/Bit"), "its child is reported through the root, not alone")
	root.free()


func _test_multimesh_gridmap() -> void:
	_section("MultiMesh and GridMap")
	var root := Node3D.new()
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Grass"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = 4
	mmi.multimesh = mm
	root.add_child(mmi)
	var empty_mmi := MultiMeshInstance3D.new()
	empty_mmi.name = "NoInstances"
	empty_mmi.multimesh = MultiMesh.new()
	root.add_child(empty_mmi)
	var lib := MeshLibrary.new()
	lib.create_item(0)
	lib.set_item_mesh(0, BoxMesh.new())
	var shaped := MeshLibrary.new()
	shaped.create_item(0)
	shaped.set_item_mesh(0, BoxMesh.new())
	shaped.set_item_shapes(0, [BoxShape3D.new(), Transform3D.IDENTITY])
	var bare_grid := GridMap.new()
	bare_grid.name = "BareGrid"
	bare_grid.mesh_library = lib
	bare_grid.set_cell_item(Vector3i.ZERO, 0)
	root.add_child(bare_grid)
	var solid_grid := GridMap.new()
	solid_grid.name = "SolidGrid"
	solid_grid.mesh_library = shaped
	solid_grid.set_cell_item(Vector3i.ZERO, 0)
	root.add_child(solid_grid)
	_check(_has(root, "Grass"), "a MultiMesh with instances and no body is reported")
	_check(not _has(root, "NoInstances"), "a MultiMesh drawing nothing is not")
	_check(_has(root, "BareGrid"), "a GridMap whose items have no shapes is reported")
	_check(not _has(root, "SolidGrid"), "a GridMap whose items have shapes is covered")
	root.free()


func _test_skipped() -> void:
	_section("Invisible nodes and bodies that move are not level geometry")
	var root := Node3D.new()
	var hidden := Node3D.new()
	hidden.name = "Hidden"
	hidden.visible = false
	hidden.add_child(_mesh("Inner"))
	root.add_child(hidden)
	var person := CharacterBody3D.new()
	person.name = "Person"
	person.add_child(_mesh("Shirt"))
	root.add_child(person)
	var crate := RigidBody3D.new()
	crate.name = "Crate"
	crate.add_child(_mesh("Skin"))
	root.add_child(crate)
	var shadow := _mesh("Shadow")
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	root.add_child(shadow)
	var nomesh := MeshInstance3D.new()
	nomesh.name = "NoMesh"
	root.add_child(nomesh)
	_check(_found(root).is_empty(), "nothing under an invisible node, a character, a rigid body, a shadow caster or an empty mesh")
	var bad := DotCollisionAudit.audit(null)
	_check(not bad.ok and bad.error.code == DotError.CODE_INVALID, "a null root is CODE_INVALID")
	root.free()


func _test_opt_out() -> void:
	_section("Opt-out by metadata and by group, inherited")
	var root := Node3D.new()
	var by_meta := Node3D.new()
	by_meta.name = "Deco"
	by_meta.set_meta(DotCollisionAudit.META, true)
	by_meta.add_child(_mesh("Flag"))
	var deep := Node3D.new()
	deep.name = "Deep"
	deep.add_child(_mesh("Flower"))
	by_meta.add_child(deep)
	root.add_child(by_meta)
	var tagged := _mesh("Water")
	root.add_child(tagged)
	var falsey := _mesh("Meta False")
	falsey.set_meta(DotCollisionAudit.META, false)
	root.add_child(falsey)
	var plain := _mesh("Plain")
	root.add_child(plain)
	# A group needs a tree; the audit asks the node, so parent the root to this scene.
	add_child(root)
	tagged.add_to_group(DotCollisionAudit.GROUP)
	var found := _found(root)
	_check(not found.has("Deco/Flag"), "metadata true opts a node out")
	_check(not found.has("Deco/Deep/Flower"), "and its descendants")
	_check(not found.has("Water"), "the group opts a node out")
	_check(found.has("Meta False"), "metadata false does not")
	_check(found.has("Plain"), "an untagged sibling is still reported")
	root.queue_free()


func _test_anywhere() -> void:
	_section("anywhere: a body in another subtree covers what it touches")
	var root := Node3D.new()
	var drawn := Node3D.new()
	drawn.name = "Drawn"
	var near := _mesh("Near")
	var far := _mesh("Far")
	far.position = Vector3(40, 0, 0)
	drawn.add_child(near)
	drawn.add_child(far)
	root.add_child(drawn)
	root.add_child(_body("Solid"))
	var strict := DotCollisionAudit.audit(root).value as DotCollisionAudit
	var loose := DotCollisionAudit.audit(root, true).value as DotCollisionAudit
	_check(strict.count() == 2, "without the option both are reported: the body is not a sibling")
	_check(loose.paths() == PackedStringArray(["Drawn/Far"]), "with it only the mesh nowhere near a shape is")
	_check(loose.examined == 2, "both were examined")
	root.free()


func _test_report() -> void:
	_section("The report describes itself")
	var root := Node3D.new()
	root.add_child(_mesh("Bare"))
	var r := DotCollisionAudit.audit(root).value as DotCollisionAudit
	var lines := r.describe_lines()
	_check(r.count() == 1 and r.examined == 1, "count and examined")
	_check(lines.size() == 2 and lines[1].contains("Bare"), "describe_lines has a header and one line per finding")
	root.free()


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("  ok    %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
