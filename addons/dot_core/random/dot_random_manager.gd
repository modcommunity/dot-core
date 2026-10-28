class_name DotRandomManager
extends Node

## The one node a game holds, and the only thing that knows the session's seed.
## No autoload: a server and a client in one process may disagree about the seed. Other addons
## find it through [DotRegistry] under [constant SERVICE] without naming this class.
## [code]var loot := rng.stream(&"loot")[/code] after [code]setup()[/code] and add_child.

## Registry name. Anything with [code]stream(name)[/code] can stand in.
const SERVICE := &"dot_random_source"

const CHANNEL := "random"

## The seed changed. Everything derived from a stream is now stale.
signal reseeded(new_seed: int)

@export var config: DotRandomConfig = null

## Whether to publish under [constant SERVICE] on [method setup]. A second manager in the
## process (a client's cosmetic stream) sets this false, or the last to register wins.
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



func current_seed() -> int:
	return _seed


## Replaces the seed and invalidates every cached stream. A stream handed out earlier keeps
## the old key (a value, not a subscription), so cachers re-ask on [signal reseeded].
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



## The named stream: the same name gives the same stream for the life of a seed. Cached, so
## two callers asking for [code]&"loot"[/code] share one counter.
func stream(name: StringName) -> DotRandomStream:
	if _root == null:
		_apply_seed(_seed)
	var hit: Variant = _cache.get(name)
	if hit != null:
		return hit as DotRandomStream
	var s := _root.stream(name)
	_cache[name] = s
	return s


## A fresh, uncached stream nobody else can advance, for a prediction that must not consume
## numbers a later replay needs.
func private_stream(name: StringName) -> DotRandomStream:
	if _root == null:
		_apply_seed(_seed)
	return _root.stream(name)


## A stream for one subject under one name — a chunk, a player, an entity.
func stream_for(name: StringName, subject: int) -> DotRandomStream:
	if _root == null:
		_apply_seed(_seed)
	return _root.stream_for(name, subject)


## A derived seed a subsystem can take away and use on its own, for addons that must not
## hard-depend on this one.
func seed_for(name: StringName) -> int:
	return stream(name).at(0)


## The names handed out so far.
func stream_names() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _cache.keys():
		out.append(String(k))
	out.sort()
	return out



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
