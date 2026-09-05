@tool
class_name DotNodeRef
extends Resource

## A configurable, inspector-editable description of "which node".
##
## [b]The problem this solves.[/b] An addon that needs to attach to something in
## the host project has three bad options: hardcode a path
## ([code]/root/Game/Players[/code], which breaks the moment anyone reorganises
## their scene), demand an autoload (which reserves a global name and forces a
## fixed tree shape), or expose a bare [NodePath] (which cannot express "the node
## in this group", "make one if it is missing", or "ask the registry").
##
## So every dot-* component that needs a host node exports one of these instead,
## and the host decides — in the inspector, per instance — how it gets resolved.
## Nothing in dot-* ever hardcodes a scene path.
##
## [codeblock]
## @export var players_root: DotNodeRef
##
## func _ready() -> void:
##     var res := players_root.resolve(self)
##     if not res.ok:
##         DotLog.result("game", "players root", res)
##         return
##     _players = res.value
## [/codeblock]
##
## Resolution is cached per context node, because these are read on hot paths
## (spawning, RPC routing) and a group query per call is wasteful. Call
## [method invalidate] if the tree changes under you.

enum Mode {
	## [member path] relative to the context node passed to [method resolve].
	## The default, and what a [NodePath] export would have given you.
	RELATIVE,
	## [member path] from the scene root ([code]/root/...[/code]).
	ABSOLUTE,
	## The context node itself. Useful as a default that means "attach to me".
	SELF,
	## The context node's parent.
	PARENT,
	## The first node in [member group]. Order is not defined when several
	## match, so this is for groups with exactly one member by construction.
	GROUP,
	## Looked up in [DotRegistry] under [member service]. The loosest coupling
	## available: neither side needs to know where the other sits.
	REGISTRY,
	## The nearest ancestor whose class or script matches [member type_name].
	ANCESTOR_OF_TYPE,
	## The first descendant of the context whose class or script matches
	## [member type_name], breadth-first.
	DESCENDANT_OF_TYPE,
	## The current scene's root.
	CURRENT_SCENE,
}

## What is missing when resolution fails.
enum OnMissing {
	## Return a failed [DotResult]. The caller decides. Default.
	FAIL,
	## Return a successful result carrying null.
	NULL,
	## Create the node and add it. See [member create_script] /
	## [member create_class].
	CREATE,
}

@export var mode: Mode = Mode.RELATIVE

@export_group("Target")

## Used by [constant Mode.RELATIVE] and [constant Mode.ABSOLUTE].
@export var path: NodePath = NodePath()

## Used by [constant Mode.GROUP].
@export var group: StringName = &""

## Used by [constant Mode.REGISTRY]. See [DotRegistry].
@export var service: StringName = &""

## Used by the two [code]*_OF_TYPE[/code] modes.
##
## Matched against the engine class name and against the [code]class_name[/code]
## of the attached script, so both [code]"CharacterBody3D"[/code] and
## [code]"MyPlayer"[/code] work.
@export var type_name: StringName = &""

@export_group("Fallback")

@export var on_missing: OnMissing = OnMissing.FAIL

## Script to instantiate when [member on_missing] is [constant OnMissing.CREATE].
## Takes precedence over [member create_class].
@export var create_script: Script = null

## Engine class to instantiate when [member on_missing] is
## [constant OnMissing.CREATE] and no [member create_script] is set.
@export var create_class: StringName = &"Node"

## Name given to a created node. Falls back to the last path segment, then to
## the class name.
@export var create_name: StringName = &""

## Where a created node is added. Empty means the context node.
@export var create_parent: NodePath = NodePath()

@export_group("Validation")

## When set, resolution fails if the node found is not of this type. Matched the
## same way as [member type_name].
##
## Worth setting on anything a host project configures by path: the failure
## "MultiplayerSpawner expected, got Sprite2D" at boot is enormously better than
## a null method call twenty minutes into a session.
@export var require_type: StringName = &""

var _cache: Dictionary = {}


# --- Construction ----------------------------------------------------------

## Builds a ref that resolves a path relative to the context.
static func of_path(p: NodePath) -> DotNodeRef:
	var r := DotNodeRef.new()
	r.mode = Mode.RELATIVE
	r.path = p
	return r


## Builds a ref that resolves to the context node itself.
static func of_self() -> DotNodeRef:
	var r := DotNodeRef.new()
	r.mode = Mode.SELF
	return r


static func of_group(g: StringName) -> DotNodeRef:
	var r := DotNodeRef.new()
	r.mode = Mode.GROUP
	r.group = g
	return r


static func of_service(s: StringName) -> DotNodeRef:
	var r := DotNodeRef.new()
	r.mode = Mode.REGISTRY
	r.service = s
	return r


## Builds a ref that creates the node if it is not already there.
##
## The pattern for optional infrastructure a component needs but a host should
## not have to place by hand — a timer, a spawner, a container.
##
## [param script_or_class] accepts a [Script] (including any [code]class_name[/code]
## global), a class name as a [String] or [StringName], or a built-in class
## reference such as [code]Node[/code]. All four appear in real call sites and
## getting any of them wrong produces a ref that silently resolves to nothing.
static func of_created(
	child_name: StringName,
	script_or_class: Variant
) -> DotNodeRef:
	var r := DotNodeRef.new()
	r.mode = Mode.RELATIVE
	r.path = NodePath(String(child_name))
	r.create_name = child_name
	r.on_missing = OnMissing.CREATE

	if script_or_class is Script:
		r.create_script = script_or_class
	else:
		r.create_class = _class_name_of(script_or_class)

	return r


## Resolves a class name from whatever a caller passed.
##
## [b]The subtle case is a built-in class reference.[/b] Writing
## [code]of_created(&"Root", Node)[/code] passes a [code]GDScriptNativeClass[/code],
## and [method String.new] on it yields
## [code]<GDScriptNativeClass#-92233...>[/code] rather than [code]"Node"[/code] —
## which becomes a create_class nothing can instantiate, so the ref resolves to null
## and whatever needed the node quietly does not work. This cost a broken game-root
## in dot-server that no parse check could have caught.
static func _class_name_of(value: Variant) -> StringName:
	if value is StringName:
		return value

	if value is String:
		return StringName(value)

	# A native class reference. There is no accessor for its name, so the only way
	# to recover it is to make one and ask. Done once, at construction.
	if value is Object and (value as Object).has_method("new"):
		var probe: Variant = (value as Object).call("new")

		if probe is Object:
			var resolved := StringName((probe as Object).get_class())

			# RefCounted frees itself; anything else would leak.
			if probe is Node:
				(probe as Node).free()
			elif not (probe is RefCounted):
				(probe as Object).free()

			return resolved

	var fallback := StringName(str(value))

	if not ClassDB.class_exists(fallback):
		push_error(
			"DotNodeRef.of_created: cannot resolve a class name from '%s'."
			% str(value)
		)

	return fallback


# --- Resolution ------------------------------------------------------------

## Finds the node.
##
## [param context] is the node doing the asking — almost always [code]self[/code].
## It anchors the relative modes and is the default parent for
## [constant OnMissing.CREATE].
func resolve(context: Node) -> DotResult:
	if context == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "DotNodeRef.resolve() needs a context node."
		)

	var key := context.get_instance_id()
	if _cache.has(key):
		var cached: Node = _cache[key]
		if is_instance_valid(cached) and cached.is_inside_tree():
			return DotResult.success(cached)
		_cache.erase(key)

	var found := _find(context)

	if found == null:
		match on_missing:
			OnMissing.NULL:
				return DotResult.success(null)
			OnMissing.CREATE:
				var created := _create(context)
				if not created.ok:
					return created
				found = created.value
			_:
				return DotResult.fail(
					DotError.CODE_INVALID,
					"Could not resolve node reference.",
					describe()
				)

	if require_type != &"" and not _matches_type(found, require_type):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Node '%s' is a %s, expected %s." % [
				found.name, found.get_class(), require_type
			],
			describe()
		)

	_cache[key] = found
	return DotResult.success(found)


## [method resolve] without the result wrapper, for call sites that genuinely
## have nothing to do about a failure. Logs at WARN and returns null.
func resolve_or_null(context: Node, channel: String = "noderef") -> Node:
	var res := resolve(context)
	if not res.ok:
		DotLog.warn(channel, res.error.message, {"ref": describe()})
		return null
	return res.value


## Drops cached resolutions. Call after re-parenting or swapping scenes.
func invalidate() -> void:
	_cache.clear()


func _find(context: Node) -> Node:
	match mode:
		Mode.SELF:
			return context

		Mode.PARENT:
			return context.get_parent()

		Mode.RELATIVE:
			if path.is_empty():
				return null
			return context.get_node_or_null(path)

		Mode.ABSOLUTE:
			if path.is_empty() or not context.is_inside_tree():
				return null
			return context.get_tree().root.get_node_or_null(path)

		Mode.CURRENT_SCENE:
			if not context.is_inside_tree():
				return null
			return context.get_tree().current_scene

		Mode.GROUP:
			if group == &"" or not context.is_inside_tree():
				return null
			return context.get_tree().get_first_node_in_group(group)

		Mode.REGISTRY:
			if service == &"":
				return null
			return DotRegistry.get_node_service(service)

		Mode.ANCESTOR_OF_TYPE:
			if type_name == &"":
				return null
			var p := context.get_parent()
			while p != null:
				if _matches_type(p, type_name):
					return p
				p = p.get_parent()
			return null

		Mode.DESCENDANT_OF_TYPE:
			if type_name == &"":
				return null
			return _find_descendant(context, type_name)

	return null


## Breadth-first so the closest match wins.
##
## Depth-first would make the answer depend on child ordering in a way that
## changes when someone reorders a scene — a resolution that silently retargets
## after a cosmetic edit is worse than no resolution.
func _find_descendant(root: Node, wanted: StringName) -> Node:
	var queue: Array[Node] = root.get_children()
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if _matches_type(n, wanted):
			return n
		queue.append_array(n.get_children())
	return null


func _create(context: Node) -> DotResult:
	var parent := context
	if not create_parent.is_empty():
		var p := context.get_node_or_null(create_parent)
		if p == null:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Cannot create node: parent '%s' not found." % create_parent,
				describe()
			)
		parent = p

	var node: Node = null

	if create_script != null:
		var inst: Variant = create_script.new()
		if not (inst is Node):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"create_script does not produce a Node.",
				describe()
			)
		node = inst
	else:
		if not ClassDB.class_exists(create_class):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Unknown class '%s'." % create_class,
				describe()
			)
		if not ClassDB.is_parent_class(create_class, "Node"):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"'%s' is not a Node." % create_class,
				describe()
			)
		node = ClassDB.instantiate(create_class) as Node

	var chosen := create_name
	if chosen == &"":
		if not path.is_empty():
			chosen = StringName(String(path).get_file())
		else:
			chosen = StringName(node.get_class())
	node.name = chosen

	parent.add_child(node)

	# Owner matters when the host saves the scene afterwards: a child with no
	# owner is silently dropped, which turns a created node into a
	# reappears-every-run mystery.
	if Engine.is_editor_hint() and parent.owner != null:
		node.owner = parent.owner

	DotLog.debug(
		"noderef",
		"created node",
		{"name": String(chosen), "parent": parent.name}
	)

	return DotResult.success(node)


## Matches against the engine class, the script's [code]class_name[/code], and
## the script's inheritance chain.
func _matches_type(node: Node, wanted: StringName) -> bool:
	if node.get_class() == String(wanted):
		return true
	if node.is_class(String(wanted)):
		return true

	var script: Variant = node.get_script()
	while script is Script:
		var s := script as Script
		if s.get_global_name() == wanted:
			return true
		script = s.get_base_script()

	return false


func describe() -> String:
	match mode:
		Mode.SELF: return "self"
		Mode.PARENT: return "parent"
		Mode.CURRENT_SCENE: return "current_scene"
		Mode.RELATIVE: return "relative:%s" % path
		Mode.ABSOLUTE: return "absolute:%s" % path
		Mode.GROUP: return "group:%s" % group
		Mode.REGISTRY: return "service:%s" % service
		Mode.ANCESTOR_OF_TYPE: return "ancestor:%s" % type_name
		Mode.DESCENDANT_OF_TYPE: return "descendant:%s" % type_name
	return "unknown"


func _to_string() -> String:
	return "DotNodeRef(%s)" % describe()
