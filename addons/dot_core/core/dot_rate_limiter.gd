class_name DotRateLimiter
extends RefCounted

## Token-bucket rate limiting, keyed by whatever you are limiting.
##
## A bucket, not a fixed window, because it permits legitimate bursts without allowing
## 3x the rate across a window boundary.
## [codeblock]
## var chat := DotRateLimiter.new(3.0, 5.0)     # 3/sec sustained, burst of 5
## if not chat.allow(peer_id):
##     return  # dropped
## [/codeblock]

## Refill rate, tokens per second.
var rate: float = 1.0

## Bucket capacity — the largest burst permitted from cold.
var burst: float = 1.0

## Buckets are dropped once idle for this long, so a server that has seen 50,000
## peers over a week is not still tracking all of them.
var idle_eviction_sec: float = 300.0

## key -> [tokens, last_seen_ticks_ms]
var _buckets: Dictionary = {}

## Least time between sweeps, in milliseconds.
var sweep_interval_ms: int = 30_000

var _last_sweep_ms: int = 0


func _init(p_rate: float = 1.0, p_burst: float = 1.0) -> void:
	rate = maxf(0.0001, p_rate)
	burst = maxf(1.0, p_burst)


## Consumes a token for [param key]; false means refuse. [param cost] charges expensive
## operations (an RCON attempt, a backbone round trip) more than a chat line.
func allow(key: Variant, cost: float = 1.0) -> bool:
	var now := Time.get_ticks_msec()
	_maybe_sweep(now)

	var tokens := burst
	if _buckets.has(key):
		var entry: Array = _buckets[key]
		var elapsed := float(now - int(entry[1])) / 1000.0
		tokens = minf(burst, float(entry[0]) + elapsed * rate)

	if tokens < cost:
		_buckets[key] = [tokens, now]
		return false

	_buckets[key] = [tokens - cost, now]
	return true


## Whether a call would be allowed, without consuming anything.
func peek(key: Variant, cost: float = 1.0) -> bool:
	if not _buckets.has(key):
		return burst >= cost

	var entry: Array = _buckets[key]
	var elapsed := float(Time.get_ticks_msec() - int(entry[1])) / 1000.0
	return minf(burst, float(entry[0]) + elapsed * rate) >= cost


## Seconds until [param cost] tokens are available, 0 when allowed now; feeds retry_after.
func retry_after(key: Variant, cost: float = 1.0) -> float:
	if not _buckets.has(key):
		return 0.0 if burst >= cost else (cost - burst) / rate

	var entry: Array = _buckets[key]
	var elapsed := float(Time.get_ticks_msec() - int(entry[1])) / 1000.0
	var tokens := minf(burst, float(entry[0]) + elapsed * rate)

	if tokens >= cost:
		return 0.0
	return (cost - tokens) / rate


## Forgets a key, restoring its full burst. Call on successful authentication so the
## failure budget does not also throttle legitimate use.
func reset(key: Variant) -> void:
	_buckets.erase(key)


func clear() -> void:
	_buckets.clear()


func tracked_count() -> int:
	return _buckets.size()


## Whether [param key] still has a bucket (one that has refilled and gone idle is dropped).
func is_tracked(key: Variant) -> bool:
	return _buckets.has(key)


## Drops buckets nobody has touched recently, swept at most every 30 seconds and only
## while something is being checked.
func _maybe_sweep(now: int) -> void:
	if now - _last_sweep_ms < sweep_interval_ms:
		return
	_last_sweep_ms = now

	var cutoff := now - int(idle_eviction_sec * 1000.0)
	var dead: Array = []
	for key in _buckets:
		var entry: Array = _buckets[key]
		# Evict only a refilled bucket, judged by elapsed time: a bucket is stored as last touched,
		# so one left at 0 tokens would never read as full, and early eviction hands out a burst.
		var refilled := float(entry[0]) + float(now - int(entry[1])) / 1000.0 * rate
		if int(entry[1]) < cutoff and refilled >= burst - 0.001:
			dead.append(key)

	for key in dead:
		_buckets.erase(key)


func describe() -> Dictionary:
	return {
		"rate": rate,
		"burst": burst,
		"tracked": _buckets.size(),
	}
