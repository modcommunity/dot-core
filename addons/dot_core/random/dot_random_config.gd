@tool
class_name DotRandomConfig
extends DotConfig

## Where a session's randomness comes from, layered like every configuration here. dot-ui
## builds a settings panel from any [DotConfig], so nothing here knows a [Control].

## The master seed; zero means "pick one at boot and announce it". Not a secret: a seed is
## meant to be shared, and a client can compute every number a server will, so hide
## anything secret behind a value the client lacks.
@export var master_seed: int = 0

## Whether to derive a fresh seed from the clock when [member master_seed] is zero. Off is
## deterministic, which a suite, a replay and a bug report want.
@export var random_when_unseeded: bool = true

## Whether the manager logs the seed it ended up with, at INFO, so a bug report is reproducible.
@export var announce_seed: bool = true

## A name mixed into every stream, so two games sharing a seed do not share a world.
@export var scope: StringName = &""


func env_prefix() -> String:
	return "DOT_RANDOM_"


func cli_prefix() -> String:
	return "--random-"


func validate() -> DotResult:
	return DotResult.success(null)
