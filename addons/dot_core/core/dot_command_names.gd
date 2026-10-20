class_name DotCommandNames
extends RefCounted

## What a commands class is called, in one place, so renaming a vote or map command is the same
## act in dot-vote, dot-map and the server's game vote.
##
## A commands class (`DotVoteCommands`, `DotMapCommands`) has a `prefix`, a `names` Dictionary
## of role to name, and a table of defaults. A role's value is a name or a list of names: the
## first is the one help text and hints show, the rest are aliases. The file side is the
## `commands:` block of maps.yml / games.yml, normalised by [DotRotationSpec].
##
## [b]A collision is a warning and a skip, never a steal.[/b] A name another command (or cvar)
## already has stays theirs and this one is not registered; an operator who renamed `rtv` to
## `map` must find the old `map` working and a line saying why theirs did not.

const CHANNEL := "core.command_names"


## Lays a normalised `commands:` block ([param spec], from [DotRotationSpec]) over
## [param target]'s `prefix` and `names`. The file wins over the code's defaults, because the
## file is the operator's.
static func apply(target: Object, spec: Dictionary) -> void:
	if spec.has("prefix"):
		target.set("prefix", str(spec["prefix"]))
	var names: Dictionary = (target.get("names") as Dictionary).duplicate()
	for role: Variant in (spec.get("names", {}) as Dictionary):
		names[str(role)] = Array((spec["names"] as Dictionary)[role])
	target.set("names", names)


## Every name a role answers to, prefix included, the primary first.
static func all_of(prefix: String, names: Dictionary, defaults: Dictionary, role: String) -> PackedStringArray:
	var raw: Variant = names.get(role, defaults.get(role, role))
	var list: Array = Array(raw) if (raw is Array or raw is PackedStringArray) else [raw]
	var out := PackedStringArray()
	for n: Variant in list:
		var full := prefix + str(n)
		if str(n) != "" and not out.has(full):
			out.append(full)
	if out.is_empty():
		out.append(prefix + role)
	return out


## Whether [param full] may be registered on [param host]: nothing else has it, and this
## binding has not taken it already. Logs the refusal. A host with no way to ask at all is
## assumed to be free of it.
static func available(host: Object, full: String, taken: PackedStringArray, role: String, owner_name: String) -> bool:
	var clash := ""
	if taken.has(full):
		clash = "another %s command" % owner_name
	elif _registry_has(host, full):
		clash = "an existing command or cvar"
	if clash == "":
		return true
	DotLog.warn(CHANNEL, "command name already in use; not registered", {
		"name": full, "role": role, "used_by": clash, "owner": owner_name,
	})
	return false


## A console answers `has_name`; a DotModule does not, but holds its server's console as
## `console`, and registering through it is exactly what would steal the name. Asking only the
## host once let a module-hosted binding take the server's own `status`.
static func _registry_has(host: Object, full: String) -> bool:
	var registry: Object = host
	if not host.has_method("has_name"):
		var c: Variant = host.get("console")
		registry = c if c is Object else null
	return registry != null and registry.has_method("has_name") and bool(registry.call("has_name", full))


## What a player types in chat to run [param full]: the server's first chat prefix, then the name.
static func typed(chat_prefix: String, full: String) -> String:
	return chat_prefix + full
