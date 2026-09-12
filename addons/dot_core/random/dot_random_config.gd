@tool
class_name DotRandomConfig
extends DotConfig

## Where a session's randomness comes from, layered like every configuration here.
##
## A settings screen for this is free: dot-ui's panel is generated from any [DotConfig],
## so nothing here has to know a [Control] exists. That is the whole of this addon's
## "integrates with dot-ui".

## The master seed. Zero means "pick one at boot and announce it".
##
## [b]Not a secret, and deliberately so.[/b] A seed is meant to be shareable — "play the
## map I played" is the single most-requested feature of every generated world — and a
## client can compute every number a server will. Anything that must be hidden from a
## player belongs behind a value the client does not have, not behind an unpublished
## seed.
@export var master_seed: int = 0

## Whether to derive a fresh seed from the clock when [member master_seed] is zero.
##
## Off makes an unseeded session deterministic, which is what a suite and a replay want,
## and what a server reproducing a bug report wants.
@export var random_when_unseeded: bool = true

## Whether the manager logs the seed it ended up with, at INFO.
##
## On, because the first question about any generated world is "what was the seed", and
## the answer being in the log is the difference between a reproducible bug report and a
## story.
@export var announce_seed: bool = true

## A name mixed into every stream, so two games sharing a seed do not share a world.
##
## An empty scope is the honest default for a single game. Setting it matters when a
## launcher hands the same seed to several titles.
@export var scope: StringName = &""


func env_prefix() -> String:
	return "DOT_RANDOM_"


func cli_prefix() -> String:
	return "--random-"


func validate() -> DotResult:
	return DotResult.success(null)
