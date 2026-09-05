class_name DotRegistry
extends RefCounted

## A name-to-object registry that replaces autoloads.
##
## [b]Why not autoloads.[/b] An addon that ships an autoload reserves a global
## identifier in every project that installs it, forces its own initialisation
## order, and cannot be instantiated twice — which rules out the two things
## dot-server actually needs to do: run a listen server and a client in one
## process for testing, and run two independent server instances in one editor
## session.
##
## So dot-* components register themselves here under a name, and anything that
## needs them either resolves a [DotNodeRef] in [constant DotNodeRef.Mode.REGISTRY]
## mode or asks directly. Registration is explicit, ordering is the host's, and
## nothing is global except this table.
##
## [codeblock]
## # In DotServer._ready()
## DotRegistry.register(&"dot_server", self)
##
## # Anywhere else
## var server := DotRegistry.get_node_service(&"dot_server") as DotServer
## [/codeblock]
##
## Names are namespaced by convention ([code]dot_server[/code],
## [code]dot_auth_client[/code]). Use [method register_scoped] when you really
## do need two of something.

## Emitted through this bus so late arrivals can wait for a service instead of
## polling. See [method await_service].
static var _bus: DotRegistryBus = null

static var _services: Dictionary = {}


static func signals() -> DotRegistryBus:
	if _bus == null:
		_bus = DotRegistryBus.new()
	return _bus


# --- Registration ----------------------------------------------------------

## Publishes [param instance] under [param name].
##
## Replacing an existing registration is allowed but logged at WARN: it is
## occasionally what you want (a hot-reloaded module) and much more often two
## copies of a node that should have been one.
##
## Nodes are automatically unregistered when they leave the tree, so callers do
## not have to pair every register with an unregister in [method Node._exit_tree]
## — the common cause of a registry holding freed objects.
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


## Registers under [code]name#scope[/code], for the genuinely-two-of-them case.
##
## A test harness running a server and a client in one process registers
## [code]dot_server#host[/code] and [code]dot_server#client[/code]; each side's
## [DotNodeRef] names the scope it wants and neither can accidentally reach the
## other.
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


## Removes a registration only if it still points at [param instance].
##
## The safe form for teardown: a node that was replaced while it was shutting
## down must not remove its successor's entry.
static func unregister_instance(name: StringName, instance: Object) -> void:
	if _services.get(name) == instance:
		unregister(name)


static func _on_node_exiting(name: StringName, node: Node) -> void:
	unregister_instance(name, node)


# --- Lookup ----------------------------------------------------------------

## The registered object, or null.
##
## Freed instances are treated as absent and their entry is dropped, so a
## registry that outlived its contents cannot hand back a dangling reference.
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


## The object, or a failed [DotResult] naming what was missing.
##
## Preferred over [method get_service] at boot, where "the server never
## registered" and "the server registered something of the wrong type" are
## different bugs and both deserve to be reported once, loudly, rather than as a
## null dereference later.
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


## Waits until [param name] is registered, then returns it.
##
## For components whose start order the host controls and who would otherwise
## need a polling timer. Times out rather than hanging forever, because a typo
## in a service name should surface as an error at boot and not as a scene that
## never finishes loading.
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


# --- Introspection ---------------------------------------------------------

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


## Drops every registration.
##
## For test teardown. Never call it in shipping code: it does not shut the
## services down, it only forgets them, so anything still running keeps running
## unreachable.
static func clear() -> void:
	_services.clear()
