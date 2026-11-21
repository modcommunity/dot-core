How an addon ships a native (Rust GDExtension) twin of a hot script path without making the library a requirement. The one existing library is [GameSpice Sim](../../dot-sim/README.md); the helper is `DotNativeParity` (API level 40).

**The rules.** The script original is the specification and the fallback. The twin gives the same answer to the bit. A caller reaches the native class only by name through `ClassDB` (`DotNativeParity.available(&"DotSimCrc")`, `ClassDB.instantiate`), never as a typed class, so scripts compile and run with no library. The library is never committed and a web export made with the plain template never carries it, so the web client always runs the script path; nothing else selects it.

**The pattern.**

```gdscript
static var _native: Object = null  # set once, null on web or with no library

static func crc32(data: PackedByteArray) -> int:
	if _native == null and DotNativeParity.available(&"DotSimCrc"):
		_native = ClassDB.instantiate(&"DotSimCrc")
	return _native.crc32(data) if _native != null else crc32_script(data)
```

Keep `crc32_script` public: the parity suite calls both.

**The parity suite.** Same inputs through both paths, compared with `DotNativeParity.same` (type and bytes: -0.0 differs from 0.0, a NaN equals itself, a Packed*Array differs by length):

```gdscript
var p := DotNativeParity.new("crc")
var r := p.compare(&"DotSimCrc", inputs, Mine.crc32_script, func(x): return Mine.crc32(x))
assert(r.status != DotNativeParity.FAIL, r.first)
```

Use seeded random inputs plus the edge cases (empty, one element, the largest), and `DotNativeParity.bench(fn, inputs)` for the before and after microseconds a commit message quotes.

**Skips are visible.** With the class absent `compare` returns `skipped`, so the suite passes on a machine without the library and says the native half did not run. On a machine that must have it (CI after `ci/install.sh`) set `GS_NATIVE_REQUIRED=1`: a skip then fails.

**Where the code goes.** The kernel in a pure crate under dot-sim's `rust/crates` (plain arrays in and out, covered by `cargo test`), engine types only in `dot-sim-gdext`, a row in dot-sim's `DotSim.MODULES` and `docs/design.md`, and the parity suite beside the script original.
