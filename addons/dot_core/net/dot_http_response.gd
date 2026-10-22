class_name DotHttpResponse
extends RefCounted

## What a [DotHttpServer] route returns: a status, headers and a body.

const REASONS := {
	200: "OK", 204: "No Content", 301: "Moved Permanently", 302: "Found", 304: "Not Modified",
	400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
	405: "Method Not Allowed", 408: "Request Timeout", 411: "Length Required",
	413: "Content Too Large", 414: "URI Too Long", 431: "Request Header Fields Too Large",
	500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable",
	505: "HTTP Version Not Supported",
}

var status := 200
## Header names are written as given; values have CR and LF stripped on the wire.
var headers: Dictionary = {}
var body := PackedByteArray()


static func make(p_status: int, p_body: PackedByteArray = PackedByteArray(), content_type: String = "") -> DotHttpResponse:
	var r := DotHttpResponse.new()
	r.status = p_status
	r.body = p_body
	if not content_type.is_empty():
		r.headers["Content-Type"] = content_type
	return r


static func text(p_status: int, s: String, content_type: String = "text/plain; charset=utf-8") -> DotHttpResponse:
	return make(p_status, s.to_utf8_buffer(), content_type)


## Serialises [param data] (anything JSON can hold) as the body.
static func json(data: Variant, p_status: int = 200) -> DotHttpResponse:
	return text(p_status, JSON.stringify(data), "application/json; charset=utf-8")


static func html(s: String, p_status: int = 200) -> DotHttpResponse:
	return text(p_status, s, "text/html; charset=utf-8")


## A plain error page for [param p_status].
static func error(p_status: int, detail: String = "") -> DotHttpResponse:
	var msg := "%d %s" % [p_status, REASONS.get(p_status, "Error")]
	return text(p_status, msg if detail.is_empty() else msg + "\n" + detail + "\n")


## The bytes to put on the wire; always closes the connection. [param head_only] omits the body for HEAD.
func to_wire(head_only: bool = false) -> PackedByteArray:
	var lines := PackedStringArray()
	lines.append("HTTP/1.1 %d %s" % [status, REASONS.get(status, "Status")])
	var seen := {}
	for k in headers:
		var name := _clean(str(k))
		if name.is_empty():
			continue
		seen[name.to_lower()] = true
		lines.append("%s: %s" % [name, _clean(str(headers[k]))])
	if not seen.has("content-length"):
		lines.append("Content-Length: %d" % body.size())
	lines.append("Connection: close")
	if not seen.has("x-content-type-options"):
		lines.append("X-Content-Type-Options: nosniff")
	var out := ("\r\n".join(lines) + "\r\n\r\n").to_utf8_buffer()
	if not head_only:
		out.append_array(body)
	return out


static func _clean(s: String) -> String:
	return s.replace("\r", "").replace("\n", "")
