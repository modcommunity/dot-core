class_name DotHttpRequest
extends RefCounted

## One parsed request handed to a [DotHttpServer] route.

var method := ""
## Percent-decoded path, always beginning with "/".
var path := ""
## Decoded query parameters; a repeated key keeps its last value.
var query: Dictionary = {}
## Header names lower-cased.
var headers: Dictionary = {}
var body := PackedByteArray()
var remote_address := ""
## Segments after the matched prefix for a prefix route, else empty.
var rest := ""


func header(name: String, default: String = "") -> String:
	return str(headers.get(name.to_lower(), default))


func body_text() -> String:
	return body.get_string_from_utf8()


## The body parsed as JSON; a failed result when it is not valid JSON.
func json_body() -> DotResult:
	var j := JSON.new()
	if j.parse(body_text()) != OK:
		return DotResult.fail(DotError.CODE_PARSE, "body is not valid JSON", j.get_error_message())
	return DotResult.success(j.data)


## The token of an "Authorization: Bearer" header, or "".
func bearer_token() -> String:
	var h := header("authorization")
	if h.length() > 7 and h.substr(0, 7).to_lower() == "bearer ":
		return h.substr(7).strip_edges()
	return ""
