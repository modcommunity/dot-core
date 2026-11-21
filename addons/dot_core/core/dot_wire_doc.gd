class_name DotWireDoc
extends RefCounted

## A JSON document as one network message: the text, deflated, behind both its lengths (`u32` text size, `u32` packed size, then the packed bytes). Games send a map, a course or a stage this way and validate what they decode, so both ends build from the same dictionary.
## Pure and static. [method decode_text] returns the text, not the dictionary: what the document must look like is the game's own validator, which reads it next.


## The most deflate expands: 1032 to 1. A header claiming more is corrupt, and decompressing it would allocate whatever it says. A bound of the format, not a limit.
const DEFLATE_RATIO := 1032


## [param doc] as bytes. [param sort_keys] makes the text, and so the bytes, the same whatever order the keys were added in.
static func encode(doc: Dictionary, sort_keys: bool = false) -> PackedByteArray:
	var raw := JSON.stringify(doc, "", sort_keys).to_utf8_buffer()
	var packed := raw.compress(FileAccess.COMPRESSION_DEFLATE)
	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, raw.size())
	out.encode_u32(4, packed.size())
	out.append_array(packed)
	return out


## The JSON text [method encode] packed, or a parse failure whose sentence names [param what] ("A map on the wire was empty."). Both lengths are checked first, so a torn or padded body is refused here rather than handed to the decompressor, which prints an engine error for it. [param max_size] bounds the unpacked size (0 is the deflate bound for these bytes).
static func decode_text(bytes: PackedByteArray, what: String = "document", max_size: int = 0) -> DotResult:
	var subject := "A %s on the wire" % what
	if bytes.size() < 9:
		return DotResult.fail(DotError.CODE_PARSE, "%s was empty." % subject)
	var size := bytes.decode_u32(0)
	if bytes.decode_u32(4) != bytes.size() - 8:
		return DotResult.fail(DotError.CODE_PARSE, "%s is not the length it says." % subject)
	var bound := max_size if max_size > 0 else (bytes.size() - 8) * DEFLATE_RATIO
	if size <= 0 or size > bound:
		return DotResult.fail(DotError.CODE_PARSE, "%s says it is %d bytes." % [subject, size])
	var raw := bytes.slice(8).decompress(size, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != size:
		return DotResult.fail(DotError.CODE_PARSE, "%s would not decompress." % subject)
	return DotResult.success(raw.get_string_from_utf8())


## A short fingerprint of a document (keys sorted), for a log line and for two ends to compare.
static func digest(doc: Dictionary) -> String:
	return JSON.stringify(doc, "", true).sha256_text().substr(0, 12)
