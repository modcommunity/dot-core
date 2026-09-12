@tool
class_name DotRandomSchedule
extends Resource

## Random events in ticks, decided by a pure function of the tick.
##
## [b]The interesting property is that it has no state.[/b] [method fires_at] asks
## whether an event happens on tick N and answers without having simulated ticks 0..N-1,
## so a client can know what the server will do, a replay can be scrubbed backwards, and
## a server restarting mid-round lands on the same schedule it was already running.
##
## A stateful scheduler — the obvious one, a countdown reset on each fire — cannot do any
## of those, and its failure mode is the one this family has hit twice: a clock that
## latches. dot-vote's director dropped a [code]vote_due[/code] that arrived while a
## cooldown was running and never offered another vote for the rest of the map.
##
## The model is a Bernoulli trial per tick at a rate derived from
## [member mean_interval_ticks], plus two rules that make it feel designed rather than
## random:
##
## - [member min_gap_ticks] — a hard floor between events, because two of anything in the
##   same second reads as a bug however correct the distribution is.
## - [member ramp_ticks] — the probability climbs from zero over this many ticks after
##   the last event, so the very short intervals the exponential distribution is full of
##   simply do not occur.
##
## [codeblock]
## var s := DotRandomSchedule.new()
## s.mean_interval_ticks = 64 * 30          # about every thirty seconds at 64 Hz
## s.min_gap_ticks = 64 * 8
## if s.fires_at(stream, tick, last_fired_tick):
##     ...
## [/codeblock]

## The average gap between events. Zero means the schedule never fires.
@export_range(0, 1000000, 1) var mean_interval_ticks: int = 600

## The shortest gap allowed. Nothing fires inside it, whatever the roll says.
@export_range(0, 1000000, 1) var min_gap_ticks: int = 120

## Ticks over which the probability ramps up from zero after the last event.
##
## Measured from the end of [member min_gap_ticks]. Zero is a flat Poisson process, which
## is statistically pure and feels arbitrary.
@export_range(0, 1000000, 1) var ramp_ticks: int = 0

## A hard ceiling on the gap. Zero is no ceiling.
##
## What a director uses to guarantee that [i]something[/i] happens: past this many ticks
## the schedule fires regardless of the roll. Pity, one layer up — and for the same
## reason, because "nothing has happened for four minutes" is indistinguishable from a
## broken game.
@export_range(0, 1000000, 1) var max_gap_ticks: int = 0

## A multiplier a game can move at runtime — difficulty, a director's intensity, a cvar.
@export_range(0.0, 100.0, 0.01, "or_greater") var rate_scale: float = 1.0


## Whether an event fires on [param tick], given that the last one was at
## [param last_tick].
##
## [param last_tick] of a negative value means "nothing has fired yet", and the gap is
## then measured from tick zero.
func fires_at(stream: DotRandomStream, tick: int, last_tick: int) -> bool:
	if stream == null or mean_interval_ticks <= 0 or rate_scale <= 0.0:
		return false

	var since := tick - maxi(last_tick, 0)
	if since < min_gap_ticks:
		return false
	if max_gap_ticks > 0 and since >= max_gap_ticks:
		return true

	var p := probability_at(since)
	if p <= 0.0:
		return false
	# Indexed by the tick rather than by a counter, which is what makes this pure. Two
	# schedules sharing a stream would otherwise answer the same question the same way on
	# the same tick; a caller with several gives each its own child stream.
	return stream.chance_at(tick, p)


## The per-tick probability [param since] ticks after the last event.
##
## Exposed because a director wants to draw it, and because a number a designer can read
## is a number a designer can tune. It is also what the self-test asserts against, rather
## than asserting one particular roll.
func probability_at(since: int) -> float:
	if mean_interval_ticks <= 0:
		return 0.0

	var effective_mean := float(mean_interval_ticks) / maxf(rate_scale, 0.0001)
	# The floor and the ramp both remove time from the distribution, so the raw rate has
	# to be higher than 1/mean for the *mean* to come out at mean. Without this the
	# measured interval is mean + min_gap + ramp/2, which is a schedule that is quietly
	# slower than the number a designer typed.
	var removed := float(min_gap_ticks) + float(ramp_ticks) * 0.5
	var target := maxf(effective_mean - removed, 1.0)
	var p := 1.0 / target

	if ramp_ticks > 0:
		var into := float(since - min_gap_ticks)
		p *= clampf(into / float(ramp_ticks), 0.0, 1.0)

	return clampf(p, 0.0, 1.0)


## The next tick at or after [param from] on which this schedule fires.
##
## Bounded rather than open-ended: a schedule configured never to fire would otherwise
## loop for ever, and "look ahead at most a minute" is what every caller actually wants.
## Returns -1 when nothing fires inside the horizon.
func next_fire(stream: DotRandomStream, from: int, last_tick: int, horizon: int = 100000) -> int:
	for t in range(from, from + maxi(1, horizon)):
		if fires_at(stream, t, last_tick):
			return t
	return -1


## The measured mean interval over [param samples] events, for tuning and for tests.
##
## A schedule is a distribution, and the only honest assertion about a distribution is
## about its shape. Asserting that tick 4,192 fires is asserting the mixer.
func measure_mean_interval(stream: DotRandomStream, samples: int = 200) -> float:
	if samples <= 0:
		return 0.0
	var last := 0
	var total := 0
	var found := 0
	var t := 1
	var limit := (maxi(mean_interval_ticks, 1) * samples * 20) + 1000
	while found < samples and t < limit:
		if fires_at(stream, t, last):
			total += t - last
			last = t
			found += 1
		t += 1
	return float(total) / float(found) if found > 0 else 0.0


func validate() -> DotResult:
	if mean_interval_ticks < 0:
		return DotResult.fail(DotError.CODE_INVALID, "mean_interval_ticks may not be negative")
	if max_gap_ticks > 0 and max_gap_ticks <= min_gap_ticks:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"max_gap_ticks is inside min_gap_ticks",
			"the ceiling would fire on the first tick the floor allows, every time"
		)
	if min_gap_ticks > 0 and mean_interval_ticks > 0 and min_gap_ticks >= mean_interval_ticks:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"min_gap_ticks is at or above the mean interval",
			"every event would land on the first legal tick, which is a metronome"
		)
	return DotResult.success(null)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("schedule: mean %d ticks, floor %d" % [mean_interval_ticks, min_gap_ticks])
	if ramp_ticks > 0:
		out.append("  ramp    %d ticks" % ramp_ticks)
	if max_gap_ticks > 0:
		out.append("  ceiling %d ticks" % max_gap_ticks)
	out.append("  rate    x%.2f" % rate_scale)
	return out
