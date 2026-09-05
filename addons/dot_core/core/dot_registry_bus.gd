class_name DotRegistryBus
extends RefCounted

## Carries [DotRegistry]'s signals, for the same reason [DotLogBus] exists:
## a static class cannot declare one.
##
## [codeblock]
## DotRegistry.signals().service_registered.connect(_on_service)
## [/codeblock]

signal service_registered(name: StringName, instance: Object)
signal service_unregistered(name: StringName)
