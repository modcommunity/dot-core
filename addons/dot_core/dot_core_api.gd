extends RefCounted

## dot-core's API level; the bump rule is on [DotAddonApi]. LEVEL rises by one for anything new a game
## could call; OLDEST is raised to LEVEL when something callable is removed or changes meaning.

# What each level added: docs/addon-api.md.
const LEVEL := 34
const OLDEST := 1
