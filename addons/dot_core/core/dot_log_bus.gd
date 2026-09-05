class_name DotLogBus
extends RefCounted

## Carries [DotLog]'s per-record signal.
##
## GDScript cannot declare a `signal` on a purely static class, and dot-core
## refuses to own an autoload, so the signal lives on this tiny object that
## [method DotLog.signals] creates on demand. Anything that would rather
## `connect` than register a [Callable] sink uses it:
##
## [codeblock]
## DotLog.signals().record.connect(_on_log_record)
## [/codeblock]
##
## Holding a reference keeps it alive; [DotLog] keeps one itself once created.

## One log record. See [method DotLog._emit] for the dictionary's shape.
signal record(rec: Dictionary)
