class_name DotRegistry
extends RefCounted

## A name-to-object registry that replaces autoloads: an autoload reserves a global name and
## cannot be instantiated twice, which rules out a server and a client in one process.
## [codeblock]
## DotRegistry.register(&"dot_server", self)
## var server := DotRegistry.get_node_service(&"dot_server") as DotServer
## [/codeblock]
## Names are namespaced by convention; use [method register_scoped] when you need two.

## Emitted through this bus so late arrivals can wait for a service instead of
## polling. See [method await_service].
static var _bus: DotRegistryBus = null

static var _services: Dictionary = {}


static func signals() -> DotRegistryBus:
	if _bus == null:
		_bus = DotRegistryBus.new()
	return _bus



## Publishes [param instance] under [param name]; replacing a registration is logged at WARN.
## Nodes unregister when they leave the tree, so callers need not pair every register.
static func register(name: StringName, instance: Object) -> void:
	if instance == null:
		push_error("DotRegistry.register(%s) with a null instance." % name)
		return

	if _services.has(name):
		var existing: Object = _services[name]
		if is_instance_valid(existing) and existing != instance:
			DotLog.warn(
				"registry",
				"replacing service registration",
				{"service": String(name), "was": existing.get_class()}
			)

	_services[name] = instance

	if instance is Node:
		var node := instance as Node
		# One-shot so a node moved between parents (which fires tree_exiting)
		# does not leave a stale connection behind.
		if not node.tree_exiting.is_connected(_on_node_exiting):
			node.tree_exiting.connect(
				_on_node_exiting.bind(name, node), CONNECT_ONE_SHOT
			)

	DotLog.debug("registry", "registered", {"service": String(name)})
	signals().service_registered.emit(name, instance)


## Registers under [code]name#scope[/code], so a server and a client in one process each
## reach only their own.
static func register_scoped(
	name: StringName,
	scope: StringName,
	instance: Object
) -> void:
	register(scoped_name(name, scope), instance)


static func scoped_name(name: StringName, scope: StringName) -> StringName:
	if scope == &"":
		return name
	return StringName("%s#%s" % [name, scope])


static func unregister(name: StringName) -> void:
	if not _services.has(name):
		return
	_services.erase(name)
	DotLog.debug("registry", "unregistered", {"service": String(name)})
	signals().service_unregistered.emit(name)


## Removes a registration only if it still points at [param instance], so a replaced node
## shutting down cannot remove its successor.
static func unregister_instance(name: StringName, instance: Object) -> void:
	if _services.get(name) == instance:
		unregister(name)


static func _on_node_exiting(name: StringName, node: Node) -> void:
	unregister_instance(name, node)



## The registered object, or null. Freed instances are treated as absent and dropped.
static func get_service(name: StringName) -> Object:
	if not _services.has(name):
		return null

	var inst: Object = _services[name]
	if not is_instance_valid(inst):
		_services.erase(name)
		return null

	return inst


static func get_node_service(name: StringName) -> Node:
	var inst := get_service(name)
	return inst as Node


static func get_scoped(name: StringName, scope: StringName) -> Object:
	return get_service(scoped_name(name, scope))


static func has(name: StringName) -> bool:
	return get_service(name) != null


## The object, or a failed [DotResult] naming what was missing, so "never registered" and
## "wrong type" are different, loud boot errors.
static func require(name: StringName, expected_class: String = "") -> DotResult:
	var inst := get_service(name)
	if inst == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"Service '%s' is not registered." % name,
			"registered: %s" % ", ".join(names())
		)

	if expected_class != "" and not inst.is_class(expected_class):
		var script: Variant = inst.get_script()
		var matched := false
		while script is Script:
			var s := script as Script
			if String(s.get_global_name()) == expected_class:
				matched = true
				break
			script = s.get_base_script()
		if not matched:
			return DotResult.fail(
				DotError.CODE_STATE,
				"Service '%s' is a %s, expected %s."
					% [name, inst.get_class(), expected_class]
			)

	return DotResult.success(inst)


## Waits until [param name] is registered, then returns it. Times out so a typo surfaces
## as a boot error and not a scene that never loads.
static func await_service(
	name: StringName,
	timeout_sec: float = 10.0
) -> DotResult:
	var existing := get_service(name)
	if existing != null:
		return DotResult.success(existing)

	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return DotResult.fail(
			DotError.CODE_STATE, "No SceneTree to wait on."
		)
	var tree := loop as SceneTree

	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		var found := get_service(name)
		if found != null:
			return DotResult.success(found)

	return DotResult.fail(
		DotError.CODE_TIMEOUT,
		"Service '%s' did not register within %.1fs." % [name, timeout_sec]
	)



static func names() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _services:
		if is_instance_valid(_services[k]):
			out.append(String(k))
	out.sort()
	return out


## For a `status`-style console command.
static func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for n in names():
		var inst := get_service(StringName(n))
		var kind := inst.get_class()
		var script: Variant = inst.get_script()
		if script is Script:
			var gn := (script as Script).get_global_name()
			if gn != &"":
				kind = String(gn)
		out.append("%-28s %s" % [n, kind])
	return out


## Drops every registration. For test teardown only: it forgets services, it does not
## shut them down.
static func clear() -> void:
	_services.clear()


## [method clear] plus the signal bus, so a headless run exits with nothing of the registry alive.
static func clear_cache() -> void:
	_services.clear()
	_bus = null
