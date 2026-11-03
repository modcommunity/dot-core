class_name DotLogBus
extends RefCounted

## Carries [DotLog]'s per-record signal: a static class cannot declare one and dot-core owns no autoload, so
## [method DotLog.signals] creates this on demand. [code]DotLog.signals().record.connect(fn)[/code]. [DotLog] keeps a reference.

## One log record. See [method DotLog._emit] for the dictionary's shape.
signal record(rec: Dictionary)
