# Reproducible randomness (`random/`)

`random/` was `dot-randomness`, a repository of its own, until it was folded in here. It belongs in dot-core because **it could never have been optional**: it already depended on `DotConfig`, `DotError`, `DotLog`, `DotRegistry` and `DotResult`, and while it sat behind an extra addon nobody installed it. Determinism has to arrive with dot-core or it does not arrive.

## Addons that hand-rolled a generator

These wrote their own instead of using this one. Two of them hand-rolled the same algorithm this file implements, worse.

- **Converted** (they now use `random/`): dot-spawn (it had folded its key in with `hash()`) and dot-combat (`DotSpread` had cleared the top bit of each splitmix constant to make them fit, so it mixed but was no longer the algorithm it named).
- **Not converted yet; reason unknown**: dot-map, dot-vote and dot-2d.
- **Not converted yet**: dot-team's `DotTeamRotation._roll` (`hash(String(key))` plus a splitmix-style finaliser using arithmetic `>>` with no mask, two of the traps below).
- **Not converted, deliberately at the time**: dot-procedural-generation's `DotProcGenRandom`, a counter-based splittable stream written as a second implementation because randomness was then a separate repository and only dot-core may be a hard dependency. That reason no longer holds now that this lives in dot-core.

## The one idea

**A draw is a pure function of (key, index), not a position in a moving cursor.** `at(index)` touches nothing, answers the same on every machine, and works for an index nobody has reached. `stream(name)` derives a child by hashing the name in, so two subsystems never disturb each other and the order they were created in stops mattering. Three failures this prevents have all happened in this tree:

- two peers drawing in a different order diverge for the rest of the session;
- inserting one roll changes every replay recorded before it;
- a stream a receiving peer cannot mirror, because it must *adopt* an index rather than allocate one (what `adopt()` is named for).

## The splitmix64 mixer: three traps, all silent

- **The constants are written as signed decimals.** All three are above 2^63 and GDScript's `int` is signed, so the hex spelling either fails to parse or quietly becomes a float, and a mixer that is a float is not a mixer.
- **`>>` is arithmetic.** Shifting a negative value keeps the sign bits, so the top of the output is a run of ones. `_unsigned_shift` masks after the shift. Half of every mixer's output has the high bit set, so this is half the cases, not an edge.
- **Take the bits you meant to take.** `DotSpread.unit()` took 23 where it meant 24 and never returned a value above 0.5: every shotgun pattern was a half-moon while a maximum-magnitude assertion passed. The suites count quadrants and buckets and never assert one particular number.

## Other decisions

- **`_hash_name` is FNV-1a, not `String.hash()`**, which is 32-bit and not promised stable across engine versions: a seed that means a different world after an engine upgrade was never shareable.
- **`mix4` and `unit_from` are public on purpose.** A subsystem whose draw is a pure function of several integers has nowhere to keep a stream object and will not allocate one per pellet; with no shared entry point it writes its own mixer, which is how the family got two.
- **The seed is public.** A client can compute every number the server will, so anything that must be secret from a player belongs behind a value they do not have.

`examples/randomness_selftest.tscn` covers it.
