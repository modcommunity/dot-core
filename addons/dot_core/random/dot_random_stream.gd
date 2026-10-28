class_name DotRandomStream
extends RefCounted

## A named, counter-based, splittable random stream: a draw is a pure function of (key, index), so peers drawing in a different order never diverge.
## [method at] takes any index with no history; [method stream] derives a child by name; [method next] advances a counter.
## splitmix64 is not cryptographic and the seed is public: nothing secret from a player may depend on it.

## Constants of splitmix64 as signed 64-bit values: written in hex they are above 2^63 and parse as floats.
const _GAMMA := -7046029254386353131  # 0x9E3779B97F4A7C15
const _MIX_A := -4658895280553007687  # 0xBF58476D1CE4E5B9
const _MIX_B := -7723592293110705685  # 0x94D049BB133111EB

## 53 bits, every bit a float64 mantissa holds; taking fewer once left a unit that never exceeded 0.5.
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



## A child stream independent of this one's.
## Derived by name, not index, so the stream is the same whatever order subsystems were created in.
func stream(name: StringName) -> DotRandomStream:
	var child := DotRandomStream.new(0, &"")
	child._key = _mix(_key ^ _hash_name(name) ^ _GAMMA)
	child._name = StringName("%s/%s" % [_name, name]) if _name != &"" else name
	return child


## A child for one subject (a player, an entity, a chunk).
## Not [code]stream(str(id))[/code]: it must not allocate a string per chunk.
func stream_for(name: StringName, subject: int) -> DotRandomStream:
	var child := stream(name)
	child._key = _mix(child._key ^ _mix(subject))
	return child


func name() -> StringName:
	return _name



## The raw 64-bit value at [param index]. Pure: no state is touched.
func at(index: int) -> int:
	return _mix(_key ^ _mix(index + _GAMMA))


## A float in [code][0, 1)[/code] at [param index].
func unit_at(index: int) -> float:
	return float(_unsigned_shift(at(index), 64 - _UNIT_BITS)) * _UNIT_SCALE


## An integer in [code][lo, hi][/code] (inclusive) at [param index].
## Scaled from the float: [code]x % span[/code] on a signed int is negative half the time.
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
## The spare sample is part of [method state]: a stream restored mid-pair differs from one restored between pairs.
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



## One element of [param items], or [code]null[/code] when it is empty.
func next_pick(items: Array) -> Variant:
	if items.is_empty():
		return null
	return items[next_range_i(0, items.size() - 1)]


## A shuffled copy of [param items]; the original is untouched.
## Fisher-Yates downward: the upward spelling is not uniform.
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



## A unit vector in the XY plane.
func next_direction_2d() -> Vector2:
	var a := next_range_f(0.0, TAU)
	return Vector2(cos(a), sin(a))


## A point inside the unit circle, uniformly by area.
## The square root makes it uniform; a flat radius clusters at the centre.
func next_point_in_circle(radius: float = 1.0) -> Vector2:
	var r := radius * sqrt(next_unit())
	return next_direction_2d() * r


## A unit vector on the sphere, uniformly by area.
## z flat and the ring following (equal bands of z carry equal area); two flat angles cluster at the poles.
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



## Where the counter is. Only meaningful for the sequential draws.
func counter() -> int:
	return _counter


func set_counter(value: int) -> void:
	_counter = maxi(0, value)


func reset() -> void:
	_counter = 0
	_gauss_has_spare = false


## Everything needed to continue this stream on another machine.
## The key rather than the seed: a child derived by name cannot be rebuilt without its parent.
func state() -> Dictionary:
	return {
		"key": _key,
		"name": String(_name),
		"counter": _counter,
		"spare": _gauss_spare,
		"has_spare": _gauss_has_spare,
	}


## Adopts a state produced by [method state].
## Named [code]adopt[/code], not [code]set_state[/code]: a receiver must take the index it is given, not allocate one.
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


# Public so a subsystem whose draw is a pure function of several integers (shot scatter) needn't
# allocate a stream per draw; the constants live once here, not copied with their top bits cleared.

## Mixes four integers into one well-distributed value. Pure, allocates nothing.
## Same finaliser as [method _mix], folded with the gamma between inputs: bare xor collides when two swap.
static func mix4(a: int, b: int, c: int, d: int) -> int:
	var x := _mix(a)
	x = _mix(x ^ (b + _GAMMA))
	x = _mix(x ^ (c + _GAMMA))
	return _mix(x ^ (d + _GAMMA))


## A float in [code][0, 1)[/code] from a mixed value, using the top 24 bits.
## Top bits because a multiply mixer's low bits are least mixed; 24 because a float32 holds them exactly.
## The shift must be zero-filling, or a "unit" goes negative.
static func unit_from(value: int) -> float:
	return float(_unsigned_shift(value, 40)) / 16777216.0



static func _mix(x: int) -> int:
	var z := x + _GAMMA
	z = (z ^ _unsigned_shift(z, 30)) * _MIX_A
	z = (z ^ _unsigned_shift(z, 27)) * _MIX_B
	return z ^ _unsigned_shift(z, 31)


## Logical (zero-filling) right shift.
## [code]>>[/code] is arithmetic on a signed int and keeps the sign bits; masking after the shift fixes that.
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
