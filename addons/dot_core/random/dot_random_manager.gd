class_name DotRandomManager
extends Node

## The one node a game holds, and the only thing that knows the session's seed.
##
## [codeblock]
## var rng := DotRandomManager.new()
## rng.config = my_random_config
## rng.setup()
## add_child(rng)
##
## var loot := rng.stream(&"loot")
## var world := rng.stream(&"world")
## [/codeblock]
##
## [b]No autoload, for this addon's own reason as well as the family's.[/b] A server and a
## client in one process must be able to disagree about the seed — a client mirroring a
## server has the server's, a client predicting its own cosmetic effects has its own —
## and a global would make those the same object.
##
## Other addons find it through [DotRegistry] under [constant SERVICE] and use it without
## naming this class, which is what lets dot-procedural-generation and dot-fx take a real
## stream when one exists and fall back to their own when it does not.

## Registry name. Anything with [code]stream(name)[/code] can stand in.
const SERVICE := &"dot_random_source"

const CHANNEL := "random"

## The seed changed. Everything derived from a stream is now stale.
signal reseeded(new_seed: int)

@export var config: DotRandomConfig = null

## Whether to publish under [constant SERVICE] on [method setup].
##
## A second manager in the same process — a client's cosmetic stream beside the server's
## authoritative one — sets this false, because the last one to register would otherwise
## silently become everybody's source of world generation.
@export var register_as_service: bool = true

var _root: DotRandomStream = null
var _seed: int = 0
var _cache: Dictionary = {}
var _draws: int = 0


func _init() -> void:
	if config == null:
		config = DotRandomConfig.new()


func setup() -> DotResult:
	if config == null:
		config = DotRandomConfig.new()
	var res := config.validate()
	if not res.ok:
		return res.wrap("random config")

	var s := config.master_seed
	if s == 0 and config.random_when_unseeded:
		# The clock and the engine's own generator together: the clock alone gives two
		# servers started by one script in the same second the same world.
		s = int(Time.get_unix_time_from_system() * 1000.0) ^ (randi() << 16) ^ randi()
	_apply_seed(s)

	if register_as_service:
		DotRegistry.register(SERVICE, self)
	return DotResult.success(null)


func _exit_tree() -> void:
	if register_as_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Seeds ------------------------------------------------------------------

func current_seed() -> int:
	return _seed


## Replaces the seed and invalidates every cached stream.
##
## [b]Every stream handed out before this call keeps the old key.[/b] That is deliberate
## — a caller holding a stream is holding a value, not a subscription — and it is why
## [signal reseeded] exists: a system that cached a stream re-asks for it.
func reseed(new_seed: int) -> void:
	_apply_seed(new_seed)
	reseeded.emit(_seed)


func _apply_seed(s: int) -> void:
	_seed = s
	_cache.clear()
	_draws = 0
	var scope := config.scope if config != null else &""
	_root = DotRandomStream.new(s, scope)
	if config != null and config.announce_seed:
		DotLog.info(CHANNEL, "seed", {"seed": s, "scope": String(scope)})


# --- Streams ----------------------------------------------------------------

## The named stream. The same name gives the same stream for the life of a seed.
##
## Cached, so a caller asking every frame does not allocate every frame — and so two
## callers that ask for [code]&"loot"[/code] genuinely share one counter rather than each
## getting a private copy that silently returns the same numbers.
func stream(name: StringName) -> DotRandomStream:
	if _root == null:
		_apply_seed(_seed)
	var hit: Variant = _cache.get(name)
	if hit != null:
		return hit as DotRandomStream
	var s := _root.stream(name)
	_cache[name] = s
	return s


## A fresh, uncached stream. Nobody else can advance it.
##
## What a prediction wants: a client replaying its own inputs must not consume numbers a
## later replay of the same inputs needs.
func private_stream(name: StringName) -> DotRandomStream:
	if _root == null:
		_apply_seed(_seed)
	return _root.stream(name)


## A stream for one subject under one name — a chunk, a player, an entity.
func stream_for(name: StringName, subject: int) -> DotRandomStream:
	if _root == null:
		_apply_seed(_seed)
	return _root.stream_for(name, subject)


## A derived seed a subsystem can take away and use on its own.
##
## For the addons that must not hard-depend on this one: they take an [int] and build
## whatever generator they already have, and still land on a number derived from the
## session's seed rather than on one of their own.
func seed_for(name: StringName) -> int:
	return stream(name).at(0)


## The names handed out so far.
func stream_names() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _cache.keys():
		out.append(String(k))
	out.sort()
	return out


# --- Reporting --------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"seed": _seed,
		"scope": String(config.scope) if config != null else "",
		"streams": stream_names().size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("dot-randomness")
	out.append("  seed    %d" % _seed)
	if config != null and config.scope != &"":
		out.append("  scope   %s" % config.scope)
	out.append("  streams %d" % _cache.size())
	for n in stream_names():
		var s := _cache[StringName(n)] as DotRandomStream
		out.append("    %-24s @%d" % [n, s.counter()])
	return out
