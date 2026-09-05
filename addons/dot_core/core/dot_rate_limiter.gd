class_name DotRateLimiter
extends RefCounted

## Token-bucket rate limiting, keyed by whatever you are limiting.
##
## Everything a client can make the server do needs one of these. Without them, a
## single peer can flood chat, brute-force an RCON password, spam reconnects, or
## make the server issue an HTTP request to the backbone per packet — none of
## which need a botnet, only a modified client and a loop.
##
## Token bucket rather than a fixed window because it permits legitimate bursts.
## A player typing three chat lines quickly is normal; a fixed window either
## refuses the third or, if sized for it, permits 3× the intended rate straddling
## a window boundary.
##
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

var _last_sweep_ms: int = 0


func _init(p_rate: float = 1.0, p_burst: float = 1.0) -> void:
	rate = maxf(0.0001, p_rate)
	burst = maxf(1.0, p_burst)


## Consumes a token for [param key]. Returns false when the caller should be
## refused.
##
## [param cost] charges more than one token for expensive operations — an RCON
## auth attempt or a backbone round trip should not cost the same as a chat line.
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
##
## For deciding whether to build an expensive payload before committing to send
## it — and for showing a countdown in a UI without the check itself resetting it.
func peek(key: Variant, cost: float = 1.0) -> bool:
	if not _buckets.has(key):
		return burst >= cost

	var entry: Array = _buckets[key]
	var elapsed := float(Time.get_ticks_msec() - int(entry[1])) / 1000.0
	return minf(burst, float(entry[0]) + elapsed * rate) >= cost


## Seconds until [param cost] tokens are available. 0 when allowed now.
##
## Feeds the [code]retry_after[/code] a well-behaved client honours instead of
## retrying immediately and getting refused again.
func retry_after(key: Variant, cost: float = 1.0) -> float:
	if not _buckets.has(key):
		return 0.0 if burst >= cost else (cost - burst) / rate

	var entry: Array = _buckets[key]
	var elapsed := float(Time.get_ticks_msec() - int(entry[1])) / 1000.0
	var tokens := minf(burst, float(entry[0]) + elapsed * rate)

	if tokens >= cost:
		return 0.0
	return (cost - tokens) / rate


## Forgets a key, restoring its full burst.
##
## Call on successful authentication: once a peer has proved who it is, the
## failure budget that was throttling its guesses should not also throttle its
## legitimate use.
func reset(key: Variant) -> void:
	_buckets.erase(key)


func clear() -> void:
	_buckets.clear()


func tracked_count() -> int:
	return _buckets.size()


## Drops buckets nobody has touched recently.
##
## Amortised: swept at most once every 30 seconds, and only when something is
## being checked anyway, so an idle server does no work.
func _maybe_sweep(now: int) -> void:
	if now - _last_sweep_ms < 30_000:
		return
	_last_sweep_ms = now

	var cutoff := now - int(idle_eviction_sec * 1000.0)
	var dead: Array = []
	for key in _buckets:
		var entry: Array = _buckets[key]
		# Only evict a bucket that has refilled: dropping a throttled peer's
		# bucket early would hand it a fresh burst, which is precisely the
		# thing being prevented.
		if int(entry[1]) < cutoff and float(entry[0]) >= burst - 0.001:
			dead.append(key)

	for key in dead:
		_buckets.erase(key)


func describe() -> Dictionary:
	return {
		"rate": rate,
		"burst": burst,
		"tracked": _buckets.size(),
	}
