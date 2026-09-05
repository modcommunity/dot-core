class_name DotHash
extends RefCounted

## Hashing and HMAC, in slices where the input can be large.
##
## Content integrity is the whole basis of dot-cloud's trust model: a downloaded
## PCK is mounted into the running game's filesystem, so a mismatched hash is the
## difference between a cache and an arbitrary-code-execution vector. That makes
## hashing hot, unavoidable, and applied to files far too large to hash in one
## frame — hence [DotHashJob].
##
## SHA-256 throughout. Godot exposes SHA-1 and MD5 too; neither is used here,
## because a content-addressed store whose addresses collide on demand is not a
## store.

const CHANNEL := "hash"

## Bytes hashed per [method DotJob._step].
##
## 256 KiB is roughly 0.3 ms on a mid-range desktop and a few ms on a phone —
## small enough to fit a frame budget slice, large enough that per-chunk overhead
## disappears.
const CHUNK_SIZE := 262_144


# --- One-shot --------------------------------------------------------------

static func sha256_bytes(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)

	# HashingContext.update() errors on an empty buffer, and the empty string has a
	# perfectly well-defined SHA-256 that callers legitimately hash — an empty
	# message schema, an empty config, a zero-length file.
	if not data.is_empty():
		ctx.update(data)

	return ctx.finish().hex_encode()


static func sha256_text(text: String) -> String:
	return sha256_bytes(text.to_utf8_buffer())


## Hashes a whole file at once. Blocks for the duration.
##
## Fine for a manifest or a config file. For content, use [DotHashJob]: this
## call on a 500 MB pack freezes the process for the better part of a second,
## and on web that is a frame the browser may decide has hung.
static func sha256_file(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_IO, "File not found.", path)

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(), "opening '%s'" % path
			)
		)

	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)

	while not f.eof_reached():
		var chunk := f.get_buffer(CHUNK_SIZE)
		if chunk.size() > 0:
			ctx.update(chunk)

	f.close()
	return DotResult.success(ctx.finish().hex_encode())


# --- HMAC ------------------------------------------------------------------

## HMAC-SHA256, hex encoded.
##
## Used for signing the integration-API requests dot-auth sends to the backbone
## and for HS256 JWT verification.
static func hmac_sha256(key: PackedByteArray, message: PackedByteArray) -> PackedByteArray:
	var ctx := HMACContext.new()
	var err := ctx.start(HashingContext.HASH_SHA256, key)
	if err != OK:
		push_error("HMACContext.start failed: %s" % error_string(err))
		return PackedByteArray()
	ctx.update(message)
	return ctx.finish()


static func hmac_sha256_hex(key: String, message: String) -> String:
	return hmac_sha256(key.to_utf8_buffer(), message.to_utf8_buffer()).hex_encode()


## Constant-time comparison of two byte arrays.
##
## [b]Not a micro-optimisation — a correctness requirement.[/b] Comparing a
## received MAC with [code]==[/code] returns as soon as two bytes differ, so the
## time taken leaks how many leading bytes were right. That turns forging a
## signature from 2^256 guesses into 32 rounds of 256, which is a coffee break.
## Every verification path in dot-* routes through here.
static func constant_time_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	# Length is not secret (it is fixed by the algorithm), so an early return on
	# a length mismatch leaks nothing.
	if a.size() != b.size():
		return false

	var diff := 0
	for i in range(a.size()):
		diff |= a[i] ^ b[i]
	return diff == 0


static func constant_time_equal_hex(a: String, b: String) -> bool:
	return constant_time_equal(
		a.to_lower().to_utf8_buffer(), b.to_lower().to_utf8_buffer()
	)


# --- Base64url -------------------------------------------------------------

## Base64url without padding, as JWTs and PKCE use.
##
## Godot only ships standard base64, so the two substitutions and the padding
## strip live here rather than being re-derived at each of the five call sites
## that need them.
static func base64url_encode(data: PackedByteArray) -> String:
	return (
		Marshalls.raw_to_base64(data)
			.replace("+", "-")
			.replace("/", "_")
			.replace("=", "")
	)


static func base64url_decode(s: String) -> PackedByteArray:
	var t := s.replace("-", "+").replace("_", "/")

	# Godot's decoder requires the padding that base64url omits.
	var pad := t.length() % 4
	if pad == 2:
		t += "=="
	elif pad == 3:
		t += "="
	elif pad == 1:
		# Not a valid base64 length; decoding would produce garbage silently.
		return PackedByteArray()

	return Marshalls.base64_to_raw(t)


static func base64url_encode_text(text: String) -> String:
	return base64url_encode(text.to_utf8_buffer())


static func base64url_decode_text(s: String) -> String:
	return base64url_decode(s).get_string_from_utf8()


# --- Random ----------------------------------------------------------------

## Cryptographically secure random bytes.
##
## [Crypto] rather than [RandomNumberGenerator]: the latter is a seeded PRNG
## whose output is predictable from its state, which is fine for gameplay and
## disqualifying for a PKCE verifier or a nonce.
static func random_bytes(n: int) -> PackedByteArray:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(n)


## A URL-safe random token, for nonces and PKCE verifiers.
##
## 32 bytes is the PKCE minimum that yields a 43-character verifier, which is
## what the backbone's `DeviceStartRequest` schema requires.
static func random_token(bytes: int = 32) -> String:
	return base64url_encode(random_bytes(bytes))


static func random_hex(bytes: int = 16) -> String:
	return random_bytes(bytes).hex_encode()
