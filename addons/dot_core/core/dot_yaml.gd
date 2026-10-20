class_name DotYaml
extends RefCounted

## A YAML reader for configuration files, and nothing more.
##
## [b]A deliberately small subset, and it refuses everything else rather than guessing.[/b]
## Godot ships no YAML parser and a complete one is a large program with a long history of
## parser bugs — anchors, aliases, merge keys, tags, flow collections, multi-document
## streams, five kinds of scalar quoting and a boolean type famous for turning the country
## code `NO` into `false`. None of that belongs in a file that decides what port a server
## listens on.
##
## What is supported is exactly what an operator writes in a `.yml` a human maintains:
##
## [codeblock]
## # comments, to end of line
## sv_name: "TMC Test Server"     # strings, quoted or bare
## sv_maxplayers: 64              # integers and floats
## sv_cheats: false               # true/false/yes/no/on/off
## sv_password:                   # empty -> ""
## backend:                       # nested maps, by indentation
##   type: rest
##   retries: 3
## tags:                          # sequences of scalars
##   - pvp
##   - modded
## groups:                        # sequences of maps, and maps of maps
##   admin:
##     permissions: [kick, ban]   # a flow sequence of scalars, one line
## [/codeblock]
##
## What it refuses, with a line number: tabs for indentation, an inconsistent indent, a
## key with no colon, a duplicate key in one map, an anchor, an alias, a tag, a document
## marker, a block scalar, and a flow *mapping*. Every one of those is either a mistake or
## a feature this format does not have, and both are better as an error at boot than as a
## value nobody intended.
##
## [b]It belongs in dot-core eventually and is here for now.[/b] The family's rule is that
## shared plumbing lives in dot-core and is copied by consumers, or is duplicated
## deliberately — and today this has exactly one consumer. Moving it before a second one
## exists would put a parser in fourteen repositories to serve one.

# No log channel: a parser that returns a DotResult naming the line it refused. Every
# caller (TmcConfig, TmcContent, install_games) wraps that with the file's path and
# returns it, and the host says why it did not start; a line here would say it twice.

## Longest line accepted, in characters.
##
## Bounded because a config file is sometimes fetched, sometimes mounted from a volume,
## and always read before anything has decided whether to trust it.
const MAX_LINE := 4096

## Deepest nesting accepted.
##
## Four is more than any file in `cfg/` needs. The bound exists because the parser is
## recursive and a hostile file should produce an error rather than a stack overflow.
const MAX_DEPTH := 8


## Parses YAML text into a [Dictionary].
##
## Returns a [DotResult] whose value is the top-level map, or a failure naming the line.
static func parse(text: String, source: String = "<string>") -> DotResult:
	var lines: Variant = _prepare(text, source)

	if lines is DotResult:
		return lines

	var rows: Array = lines
	var cursor := [0]
	var parsed := _parse_block(rows, cursor, 0, source, 0)

	if not parsed.ok:
		return parsed

	if cursor[0] < rows.size():
		var row: Dictionary = rows[cursor[0]]
		return _fail(source, int(row["line"]), "unexpected indentation")

	var value: Variant = parsed.value
	return DotResult.success(value if value is Dictionary else {})


## Parses a file. A missing file is a failure, not an empty map.
##
## "The file is not there" and "the file is there and empty" are different problems with
## different fixes, and a reader that collapses them makes a typo in a path look like a
## config that simply sets nothing.
static func parse_file(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(
			DotError.CODE_IO, "No such file: %s" % path
		)

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return DotResult.fail(
			DotError.CODE_IO,
			"Could not read %s." % path,
			error_string(FileAccess.get_open_error())
		)

	var text := file.get_as_text()
	file.close()
	return parse(text, path)


# --- Lexing ----------------------------------------------------------------

## Strips comments and blank lines, and measures each remaining line's indent.
##
## Returns an [Array] of rows, or a [DotResult] failure. Refuses a tab in the indent: YAML
## forbids it, editors disagree about how wide one is, and a file that mixes them nests
## differently for two people looking at the same bytes.
static func _prepare(text: String, source: String) -> Variant:
	var rows: Array = []
	var number := 0

	for raw in text.split("\n"):
		number += 1
		var line := (raw as String).trim_suffix("\r")

		if line.length() > MAX_LINE:
			return _fail(source, number, "line is longer than %d characters" % MAX_LINE)

		var stripped := line.strip_edges()

		if stripped == "" or stripped.begins_with("#"):
			continue

		if stripped == "---" or stripped == "...":
			return _fail(
				source, number,
				"document markers are not supported; this reader takes one document"
			)

		var indent := 0

		while indent < line.length() and line[indent] == " ":
			indent += 1

		if indent < line.length() and line[indent] == "\t":
			return _fail(
				source, number,
				"tabs may not indent YAML; use spaces"
			)

		rows.append({
			"line": number,
			"indent": indent,
			"text": _strip_comment(stripped),
		})

	return rows


## Removes a trailing comment, respecting quotes.
##
## A `#` inside a quoted string is data. Without this, `sv_name: "Bob's #1 server"` becomes
## `"Bob's` and the server is named something nobody typed.
static func _strip_comment(text: String) -> String:
	var quote := ""
	var index := 0

	while index < text.length():
		var ch := text[index]

		if quote != "":
			if ch == "\\" and quote == "\"":
				index += 2
				continue
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#" and (index == 0 or text[index - 1] == " "):
			return text.substr(0, index).strip_edges()

		index += 1

	return text.strip_edges()


# --- Parsing ---------------------------------------------------------------

## Parses one indented block: a map, or a sequence.
##
## [param cursor] is a one-element [Array] used as a mutable index — GDScript lambdas and
## calls copy an [int] and this has to be shared across the recursion.
static func _parse_block(
	rows: Array,
	cursor: Array,
	indent: int,
	source: String,
	depth: int
) -> DotResult:
	if depth > MAX_DEPTH:
		return _fail(source, _line_at(rows, cursor), "nested deeper than %d" % MAX_DEPTH)

	if cursor[0] >= rows.size():
		return DotResult.success({})

	var first: Dictionary = rows[cursor[0]]

	if String(first["text"]).begins_with("- "):
		return _parse_sequence(rows, cursor, indent, source, depth)

	return _parse_map(rows, cursor, indent, source, depth)


static func _parse_map(
	rows: Array,
	cursor: Array,
	indent: int,
	source: String,
	depth: int
) -> DotResult:
	var out := {}

	while cursor[0] < rows.size():
		var row: Dictionary = rows[cursor[0]]
		var row_indent := int(row["indent"])

		if row_indent < indent:
			break

		if row_indent > indent:
			return _fail(source, int(row["line"]), "unexpected indentation")

		var text := String(row["text"])

		if text.begins_with("- "):
			# A sequence entry where a mapping key was expected. Legal YAML in some
			# positions and never what a config file means here.
			return _fail(source, int(row["line"]), "expected a key, found a list item")

		var split := _split_key(text)

		if split.is_empty():
			return _fail(
				source, int(row["line"]),
				"expected 'key: value', found '%s'" % text
			)

		var key := String(split["key"])
		var rest := String(split["value"])

		if out.has(key):
			# Refused rather than overwritten. YAML says the last one wins, which means a
			# duplicated key silently discards the one an operator meant to edit — and the
			# two are usually far enough apart in the file that nobody sees both.
			return _fail(source, int(row["line"]), "duplicate key '%s'" % key)

		cursor[0] += 1

		if rest != "":
			var scalar: Variant = _parse_scalar(rest, source, int(row["line"]))

			if scalar is DotResult:
				return scalar

			out[key] = scalar
			continue

		# Nothing after the colon: either a nested block, or an empty value.
		var child_indent := _next_indent(rows, cursor)

		if child_indent > indent:
			var child := _parse_block(rows, cursor, child_indent, source, depth + 1)

			if not child.ok:
				return child

			out[key] = child.value
		else:
			out[key] = ""

	return DotResult.success(out)


static func _parse_sequence(
	rows: Array,
	cursor: Array,
	indent: int,
	source: String,
	depth: int
) -> DotResult:
	var out: Array = []

	while cursor[0] < rows.size():
		var row: Dictionary = rows[cursor[0]]
		var row_indent := int(row["indent"])

		if row_indent < indent:
			break

		if row_indent > indent:
			return _fail(source, int(row["line"]), "unexpected indentation")

		var text := String(row["text"])

		if not text.begins_with("- "):
			if text == "-":
				return _fail(
					source, int(row["line"]), "a list item needs a value on the same line"
				)
			break

		var body := text.substr(2).strip_edges()
		cursor[0] += 1

		# `- key: value` starts a map at the item's own indent. Handled by rewriting the
		# row in place rather than by a second parser: the alternative is two code paths
		# for a mapping and they drift.
		var inner := _split_key(body)

		if not inner.is_empty() and not _looks_quoted(body):
			var item_indent := indent + 2
			rows[cursor[0] - 1] = {
				"line": row["line"], "indent": item_indent, "text": body,
			}
			cursor[0] -= 1

			var mapped := _parse_map(rows, cursor, item_indent, source, depth + 1)

			if not mapped.ok:
				return mapped

			out.append(mapped.value)
			continue

		var scalar: Variant = _parse_scalar(body, source, int(row["line"]))

		if scalar is DotResult:
			return scalar

		out.append(scalar)

	return DotResult.success(out)


## Splits `key: value` at the first colon outside quotes. Empty when there is none.
static func _split_key(text: String) -> Dictionary:
	var quote := ""
	var index := 0

	while index < text.length():
		var ch := text[index]

		if quote != "":
			if ch == "\\" and quote == "\"":
				index += 2
				continue
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == ":":
			# A colon inside a bare scalar — a URL's `http://` — is only a key separator
			# when a space or the end of the line follows it. That is YAML's own rule and
			# it is the one that makes `url: http://host:8000` parse.
			if index + 1 >= text.length() or text[index + 1] == " ":
				return {
					"key": _unquote(text.substr(0, index).strip_edges()),
					"value": text.substr(index + 1).strip_edges(),
				}

		index += 1

	return {}


static func _looks_quoted(text: String) -> bool:
	return text.begins_with("\"") or text.begins_with("'")


static func _next_indent(rows: Array, cursor: Array) -> int:
	if cursor[0] >= rows.size():
		return -1

	return int((rows[cursor[0]] as Dictionary)["indent"])


static func _line_at(rows: Array, cursor: Array) -> int:
	if cursor[0] >= rows.size():
		return 0

	return int((rows[cursor[0]] as Dictionary)["line"])


# --- Scalars ---------------------------------------------------------------

## Turns a scalar into a typed value, or returns a [DotResult] failure.
##
## Types are inferred, which is what makes a config file readable — and the inference is
## deliberately narrow. A quoted value is always a string, so `sv_maxplayers: "64"` and
## `country: "NO"` mean what they say.
static func _parse_scalar(text: String, source: String, line: int) -> Variant:
	if text == "":
		return ""

	for prefix in ["&", "*", "!", "|", ">"]:
		if text.begins_with(prefix):
			return _fail(
				source, line,
				"anchors, aliases, tags and block scalars are not supported ('%s')" % text
			)

	if text.begins_with("{"):
		return _fail(
			source, line,
			"an inline mapping is not supported; indent it on the following lines"
		)

	if text.begins_with("["):
		return _parse_flow_sequence(text, source, line)

	if _looks_quoted(text):
		return _unquote(text)

	var lowered := text.to_lower()

	if lowered in ["true", "yes", "on"]:
		return true

	if lowered in ["false", "no", "off"]:
		return false

	if lowered in ["null", "~"]:
		return ""

	if text.is_valid_int():
		return text.to_int()

	if text.is_valid_float():
		return text.to_float()

	return text


## `[a, b, c]` on one line. Scalars only.
static func _parse_flow_sequence(text: String, source: String, line: int) -> Variant:
	if not text.ends_with("]"):
		return _fail(source, line, "a flow sequence must close on the same line")

	var body := text.substr(1, text.length() - 2).strip_edges()
	var out: Array = []

	if body == "":
		return out

	for part in _split_flow(body):
		var value: Variant = _parse_scalar(String(part).strip_edges(), source, line)

		if value is DotResult:
			return value

		out.append(value)

	return out


## Splits on commas outside quotes.
static func _split_flow(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var quote := ""
	var start := 0
	var index := 0

	while index < text.length():
		var ch := text[index]

		if quote != "":
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == ",":
			out.append(text.substr(start, index - start))
			start = index + 1

		index += 1

	out.append(text.substr(start))
	return out


static func _unquote(text: String) -> String:
	if text.length() >= 2:
		if text.begins_with("\"") and text.ends_with("\""):
			return text.substr(1, text.length() - 2) \
				.replace("\\\"", "\"").replace("\\\\", "\\").replace("\\n", "\n")

		if text.begins_with("'") and text.ends_with("'"):
			return text.substr(1, text.length() - 2).replace("''", "'")

	return text


static func _fail(source: String, line: int, why: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_PARSE,
		"%s:%d: %s" % [source, line, why]
	)


# --- Reading a parsed tree -------------------------------------------------

## Fetches a nested value by a dotted path. Missing returns [param fallback].
##
## `DotYaml.at(cfg, "backend.verify.type", "jwt")`. Exists so a caller reads a setting in
## one line without a chain of `has()` checks — every one of which is a place to forget one.
static func at(tree: Dictionary, path: String, fallback: Variant = null) -> Variant:
	var node: Variant = tree

	for part in path.split("."):
		if not (node is Dictionary) or not (node as Dictionary).has(part):
			return fallback

		node = (node as Dictionary)[part]

	return node
