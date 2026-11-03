class_name DotRegistryBus
extends RefCounted

## Carries [DotRegistry]'s signals, as [DotLogBus] does for logs: a static class cannot declare one.
## [code]DotRegistry.signals().service_registered.connect(fn)[/code].

signal service_registered(name: StringName, instance: Object)
signal service_unregistered(name: StringName)
