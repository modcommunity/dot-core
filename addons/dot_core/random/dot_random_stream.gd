class_name DotRandomStream
extends RefCounted

## A named, counter-based, splittable random stream.
##
## [b]The whole design is one sentence: a draw is a pure function of (key, index), and
## nothing shares an index with anything else.[/b] That is not how [RandomNumberGenerator]
## works and the difference is the entire reason this class exists.
##
## A conventional generator is a piece of mutable state that every caller advances. In a
## single-player game that is fine. In this family it is three separate bugs waiting:
##
## [b]1. Two peers that draw in a different order diverge.[/b] A server that rolls spread
## for a shot, then a loot drop, and a client that predicts the shot and never sees the
## loot, are two machines one draw apart for the rest of the session. Every subsequent
## number disagrees, and the symptom is not "the loot is wrong" — it is that the
## [i]shooting[/i] stops matching, which points at the netcode.
##
## [b]2. Adding a feature changes the past.[/b] Inserting one extra draw anywhere shifts
## every later number, so a replay recorded yesterday plays back differently today and a
## seed somebody shared stops producing the map they shared it for.
##
## [b]3. A stream nobody can resume.[/b] dot-2d shipped exactly this: a scatter field a
## receiving peer could not mirror, because it had to [i]adopt[/i] an index rather than
## allocate one. [method at] is the same lesson generalised — any index, any time, any
## machine, no history required.
##
## So: [method stream] derives a child by hashing a name into the key, and two children
## never disturb each other however often either is drawn from. [method next] advances a
## counter for convenience; [method at] does not advance anything at all.
##
## [codeblock]
## var world := DotRandomStream.new(seed)
## var loot := world.stream(&"loot")
## var spread := world.stream(&"spread")
##
## spread.at(tick)          # the same number on every machine, for ever
## loot.next_range_i(1, 6)  # and drawing it does not move `spread`
## [/codeblock]
##
## The mixer is splitmix64. It is not cryptographic and must not be used where that
## matters — [member DotRandomConfig.master_seed] is public, a seed is meant to be shareable,
## and a client can compute every number the server will. Anything that has to be secret
## from a player (a hidden card, a server's tie-break) belongs behind a value the client
## does not have.

## Constants of splitmix64, written as their signed 64-bit values.
##
## GDScript's [int] is signed and these three are all above 2^63, so spelling them in hex
## either fails to parse or silently becomes a float, which is a mixer that is not a
## mixer. Written out, the arithmetic wraps exactly as the reference does.
const _GAMMA := -7046029254386353131  # 0x9E3779B97F4A7C15
const _MIX_A := -4658895280553007687  # 0xBF58476D1CE4E5B9
const _MIX_B := -7723592293110705685  # 0x94D049BB133111EB

## 53 bits, which is every bit a float64 mantissa can hold.
##
## [b]Taking fewer is a bug this family has already shipped.[/b] `DotSpread.unit()` took
## the top of a 63-bit value, shifted by 40 and masked 24, which leaves 23 — so it never
## returned a value above 0.5, every shotgun pattern was a half-moon, and a
## maximum-magnitude assertion passed the whole time. The self-test here checks the
## quadrants, not the maximum.
const _UNIT_BITS := 53
const _UNIT_SCALE := 1.0 / 9007199254740992.0  # 2^53

var _key: int = 0
var _name: StringName = &""
var _counter: int = 0

## A cached second sample from Box-Muller, which produces two at a time.
var _gauss_spare: float = 0.0
var _gauss_has_spare: bool = false


func _init(p_seed: int = 0, p_name: StringName = &"") -> void:
	_name = p_name
	_key = _mix(p_seed ^ _hash_name(p_name))


# --- Deriving ---------------------------------------------------------------

## A child stream whose numbers are independent of this one's.
##
## Deriving by name rather than by index is deliberate: a caller that says
## [code]stream(&"loot")[/code] gets the same stream in every build, whatever order the
## subsystems happened to be created in. An index would make the loot table depend on
## whether the audio system asked for a stream first.
func stream(name: StringName) -> DotRandomStream:
	var child := DotRandomStream.new(0, &"")
	child._key = _mix(_key ^ _hash_name(name) ^ _GAMMA)
	child._name = StringName("%s/%s" % [_name, name]) if _name != &"" else name
	return child


## A child for one subject — a player, an entity, a chunk.
##
## The reason this is not [code]stream(str(id))[/code] is that it must be cheap: a
## generator that allocates a string per chunk allocates a string per chunk.
func stream_for(name: StringName, subject: int) -> DotRandomStream:
	var child := stream(name)
	child._key = _mix(child._key ^ _mix(subject))
	return child


func name() -> StringName:
	return _name


# --- Indexed draws, which advance nothing -----------------------------------

## The raw 64-bit value at [param index]. Pure: no state is touched.
func at(index: int) -> int:
	return _mix(_key ^ _mix(index + _GAMMA))


## A float in [code][0, 1)[/code] at [param index].
func unit_at(index: int) -> float:
	return float(_unsigned_shift(at(index), 64 - _UNIT_BITS)) * _UNIT_SCALE


## An integer in [code][lo, hi][/code] (inclusive) at [param index].
##
## Scaled from the float rather than taken modulo the raw value. [code]x % span[/code]
## on a signed 64-bit int is negative for half of every mixer's output, so the obvious
## spelling returns values below [param lo] about half the time — and it does it
## silently, because a number below the range is still a number.
func range_i_at(index: int, lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	var span := hi - lo + 1
	return lo + int(unit_at(index) * float(span)) % span


## A float in [code][lo, hi)[/code] at [param index].
func range_f_at(index: int, lo: float, hi: float) -> float:
	return lo + unit_at(index) * (hi - lo)


## Whether an event of probability [param p] happens at [param index].
func chance_at(index: int, p: float) -> bool:
	if p <= 0.0:
		return false
	if p >= 1.0:
		return true
	return unit_at(index) < p


# --- Sequential draws -------------------------------------------------------

## The next raw value, advancing the counter.
func next() -> int:
	var v := at(_counter)
	_counter += 1
	return v


func next_unit() -> float:
	var v := unit_at(_counter)
	_counter += 1
	return v


func next_range_i(lo: int, hi: int) -> int:
	var v := range_i_at(_counter, lo, hi)
	_counter += 1
	return v


func next_range_f(lo: float, hi: float) -> float:
	var v := range_f_at(_counter, lo, hi)
	_counter += 1
	return v


func next_chance(p: float) -> bool:
	var v := chance_at(_counter, p)
	_counter += 1
	return v


## -1 or 1.
func next_sign() -> int:
	return -1 if next_chance(0.5) else 1


## A normally distributed value, by Box-Muller.
##
## The spare is kept because the transform produces two samples from two uniforms and
## throwing one away doubles the cost. It is part of [method state] for that reason: a
## stream restored mid-pair and one restored between pairs are not the same stream, and
## a replay that ignores the spare drifts by one sample somewhere in the middle.
func next_gaussian(mean: float = 0.0, deviation: float = 1.0) -> float:
	if _gauss_has_spare:
		_gauss_has_spare = false
		return mean + _gauss_spare * deviation

	var u := 0.0
	var v := 0.0
	var s := 0.0
	# Marsaglia's polar form: rejects points outside the unit circle, which is where the
	# loop comes from. It converges in about 1.27 iterations on average; the cap is there
	# so a pathological key cannot hang a frame.
	for _i in range(64):
		u = next_unit() * 2.0 - 1.0
		v = next_unit() * 2.0 - 1.0
		s = u * u + v * v
		if s > 0.0 and s < 1.0:
			break
	if s <= 0.0 or s >= 1.0:
		return mean

	var f := sqrt(-2.0 * log(s) / s)
	_gauss_spare = v * f
	_gauss_has_spare = true
	return mean + u * f * deviation


# --- Collections ------------------------------------------------------------

## One element of [param items], or [code]null[/code] when it is empty.
func next_pick(items: Array) -> Variant:
	if items.is_empty():
		return null
	return items[next_range_i(0, items.size() - 1)]


## A shuffled copy of [param items]. The original is not touched.
##
## Fisher-Yates downward, which is the only version that is uniform. The upward spelling
## — swapping element i with a random element of the whole array — produces n^n equally
## likely paths over n! permutations, so some orderings are strictly more likely than
## others. It looks shuffled and is not.
func next_shuffled(items: Array) -> Array:
	var out := items.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := next_range_i(0, i)
		var tmp: Variant = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out


## [param count] distinct elements of [param items], in a random order.
func next_sample(items: Array, count: int) -> Array:
	if count >= items.size():
		return next_shuffled(items)
	return next_shuffled(items).slice(0, maxi(count, 0))


## An index into [param weights], proportional to them. -1 when they sum to nothing.
func next_weighted(weights: PackedFloat32Array) -> int:
	var total := 0.0
	for w in weights:
		if w > 0.0:
			total += w
	if total <= 0.0:
		return -1
	var roll := next_unit() * total
	for i in range(weights.size()):
		var w := weights[i]
		if w <= 0.0:
			continue
		roll -= w
		if roll <= 0.0:
			return i
	# Floating point can leave a hair of the total unconsumed. Answering -1 here would be
	# a one-in-a-few-million "nothing dropped" that nobody can reproduce.
	for i in range(weights.size() - 1, -1, -1):
		if weights[i] > 0.0:
			return i
	return -1


# --- Geometry ---------------------------------------------------------------

## A unit vector in the XY plane.
func next_direction_2d() -> Vector2:
	var a := next_range_f(0.0, TAU)
	return Vector2(cos(a), sin(a))


## A point inside the unit circle, uniformly by area.
##
## The square root is what makes it uniform. Without it — radius drawn flat — half the
## points land in the inner quarter of the area and a scatter looks like a target.
func next_point_in_circle(radius: float = 1.0) -> Vector2:
	var r := radius * sqrt(next_unit())
	return next_direction_2d() * r


## A unit vector on the sphere, uniformly by area.
##
## z is drawn flat and the ring follows, which is Archimedes' result: equal bands of z
## carry equal area. Drawing two angles flat instead clusters at the poles.
func next_direction_3d() -> Vector3:
	var z := next_range_f(-1.0, 1.0)
	var a := next_range_f(0.0, TAU)
	var r := sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(r * cos(a), r * sin(a), z)


## A unit vector within [param degrees] of [param axis], uniformly by solid angle.
func next_cone(axis: Vector3, degrees: float) -> Vector3:
	var dir := axis.normalized()
	if dir == Vector3.ZERO:
		dir = Vector3.FORWARD
	var cos_max := cos(deg_to_rad(clampf(degrees, 0.0, 180.0)))
	var z := next_range_f(cos_max, 1.0)
	var a := next_range_f(0.0, TAU)
	var r := sqrt(maxf(0.0, 1.0 - z * z))
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var right := dir.cross(up).normalized()
	var fwd := right.cross(dir).normalized()
	return (right * (r * cos(a)) + fwd * (r * sin(a)) + dir * z).normalized()


# --- State ------------------------------------------------------------------

## Where the counter is. Only meaningful for the sequential draws.
func counter() -> int:
	return _counter


func set_counter(value: int) -> void:
	_counter = maxi(0, value)


func reset() -> void:
	_counter = 0
	_gauss_has_spare = false


## Everything needed to continue this stream on another machine.
##
## The key is in here rather than the seed, because a child derived by name cannot be
## rebuilt without knowing the parent — and a peer adopting a stream should not have to
## know the tree it came from. dot-2d's scatter learned that the hard way.
func state() -> Dictionary:
	return {
		"key": _key,
		"name": String(_name),
		"counter": _counter,
		"spare": _gauss_spare,
		"has_spare": _gauss_has_spare,
	}


## Adopts a state produced by [method state].
##
## Named [code]adopt[/code] rather than [code]set_state[/code] on purpose: dot-2d's
## scatter field could not be mirrored because a receiving peer was allocating an index
## where it should have been taking the one it was given, and the word is the reminder.
func adopt(s: Dictionary) -> DotResult:
	if not s.has("key"):
		return DotResult.fail(DotError.CODE_INVALID, "a stream state needs a key")
	_key = int(s.get("key", 0))
	_name = StringName(str(s.get("name", "")))
	_counter = maxi(0, int(s.get("counter", 0)))
	_gauss_spare = float(s.get("spare", 0.0))
	_gauss_has_spare = bool(s.get("has_spare", false))
	return DotResult.success(self)


## An independent copy, at the same position.
func duplicate_stream() -> DotRandomStream:
	var c := DotRandomStream.new()
	c.adopt(state())
	return c


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("stream %s" % (String(_name) if _name != &"" else "<unnamed>"))
	out.append("  key      %d" % _key)
	out.append("  counter  %d" % _counter)
	out.append("  next     %.6f" % unit_at(_counter))
	return out


func _to_string() -> String:
	return "DotRandomStream(%s @%d)" % [String(_name), _counter]


# --- The mixer, as the rest of the family uses it ----------------------------
#
# [b]These two are public because the alternative was measured and is worse.[/b] A
# subsystem whose draw is a pure function of several integers -- shot scatter being
# the case that forced this -- cannot use a stream object: it has no place to keep
# one, and allocating a stream per pellet to draw one number from it is not a trade
# anybody would make. So dot-combat wrote its own splitmix64, and in writing it down
# discovered that GDScript parses the published constants as floats (every one is
# above 2^63, and [int] is signed), and cleared their top bits to make them fit.
#
# That leaves a mixer that still mixes but is no longer the algorithm it names, in
# the one place in a shooter where a client and a server disagreeing is invisible
# until somebody says a weapon "feels off". The fix is not to be cleverer over there
# -- it is for the constants to be written once, here, where the comment explaining
# the negative literals lives.

## Mixes four integers into one well-distributed value. Pure, allocates nothing.
##
## The same splitmix64 finaliser [method _mix] uses, fed a folded combination of the
## four inputs rather than one. [b]Folded with the gamma between them, not xored
## bare:[/b] four values xored together collide whenever two of them swap, so
## (entity 3, pellet 7) and (entity 7, pellet 3) would fire the same pattern.
static func mix4(a: int, b: int, c: int, d: int) -> int:
	var x := _mix(a)
	x = _mix(x ^ (b + _GAMMA))
	x = _mix(x ^ (c + _GAMMA))
	return _mix(x ^ (d + _GAMMA))


## A float in [code][0, 1)[/code] from a mixed value, using the top 24 bits.
##
## The TOP bits, because the low bits of a multiply-based mixer are the least mixed;
## 24 of them, because that is what a 32-bit float represents exactly, so the same
## number comes back on a platform whose intermediates are 64-bit and one whose are
## not.
##
## [b]The shift has to be zero-filling.[/b] Half of every value a mixer produces has
## the high bit set, and an arithmetic shift of one of those keeps the sign bits --
## which does not merely bias the result, it makes it negative, and a "unit" that can
## be less than zero becomes an angle pointing backwards.
static func unit_from(value: int) -> float:
	return float(_unsigned_shift(value, 40)) / 16777216.0


# --- The mixer --------------------------------------------------------------

static func _mix(x: int) -> int:
	var z := x + _GAMMA
	z = (z ^ _unsigned_shift(z, 30)) * _MIX_A
	z = (z ^ _unsigned_shift(z, 27)) * _MIX_B
	return z ^ _unsigned_shift(z, 31)


## Logical (zero-filling) right shift.
##
## GDScript's [code]>>[/code] is arithmetic on a signed 64-bit int, so shifting a
## negative value keeps the sign bits and the top of the mixer's output is then a run of
## ones rather than entropy. Masking after the shift is what makes it logical. Half of
## every value a mixer produces has the high bit set, so this is not an edge case — it
## is half of them.
static func _unsigned_shift(value: int, bits: int) -> int:
	if bits <= 0:
		return value
	if bits >= 64:
		return 0
	return (value >> bits) & ((1 << (64 - bits)) - 1)


static func _hash_name(name: StringName) -> int:
	var s := String(name)
	if s.is_empty():
		return 0
	# FNV-1a over the UTF-8 bytes. Godot's own String.hash() is 32-bit and, more to the
	# point, is not promised to be stable across engine versions — and a seed that means
	# a different world after an engine upgrade is a seed that was never shareable.
	var h := -3750763034362895579  # 0xCBF29CE484222325
	for b in s.to_utf8_buffer():
		h = (h ^ b) * 1099511628211
	return h
