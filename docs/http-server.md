# DotHttpServer

A small HTTP/1.1 server for admin pages and JSON endpoints (`net/dot_http_server.gd`, with `DotHttpRequest` and `DotHttpResponse`). It is for dot-workbench-style surfaces, not for serving a public site: one request per connection, `Connection: close`, no keep-alive, no chunked bodies, no pipelining, no `Expect: 100-continue`.

## Use

```gdscript
var http := DotHttpServer.new()
http.route("GET", "/status", func(r: DotHttpRequest) -> DotHttpResponse: return DotHttpResponse.json({"ok": true}))
http.serve_dir("/static", "res://web")
var res := http.start(8790)          # 127.0.0.1 by default
# in the host's _process: http.poll()
```

`start(port, bind, cert_path, key_path)` returns a `DotResult` whose value is the bound port (port 0 picks one). `start_from_config(dict)` reads `bind`, `port`, `tls_mode` (`native` uses `cert` and `key`; anything else is plain HTTP, meant for a reverse proxy), `cert`, `key`. Refused on web through `DotPlatform.can_listen()` (`CODE_UNSUPPORTED`).

Handlers are `Callable(DotHttpRequest) -> DotHttpResponse` and run synchronously inside `poll()`; a handler returning anything else is a 500. `route` matches an exact path (HEAD uses the GET route and drops the body); `route_prefix` matches whole path segments, the longest prefix wins, and the remainder is `request.rest`. A known path with another method is 405 with `Allow`.

## Polling and threads

Everything happens in `poll()`: accept, read what has arrived, parse, dispatch, write what the socket takes. There are no threads, so the server runs the same wherever `TCPServer` does, and a slow handler stalls the frame.

## Limits and status codes

| Status | When | Setting |
| --- | --- | --- |
| 400 | malformed request line, header, percent-escape, control or non-ASCII byte, bare LF, bad or conflicting `Content-Length`, absolute-form target | |
| 408 | request not complete (or response not sent) within the timeout | `read_timeout_sec`, `write_timeout_sec` (10 s) |
| 411 | POST, PUT or PATCH with no `Content-Length` | |
| 413 | body over the limit | `max_body_bytes` (1 MiB) |
| 414 | request line too long | `max_request_line` (2048) |
| 431 | head over the limit, or too many headers | `max_head_bytes` (8192), `max_headers` (64) |
| 501 | `Transfer-Encoding` present | |
| 503 | more connections than `max_connections` (64) | |
| 505 | version other than HTTP/1.0 or 1.1 | |

A rejected request never reaches a route. Rejections log at DEBUG on channel `http_server` (scanners are routine); start and stop log INFO; a non-loopback plain-HTTP bind logs WARN. Response header names and values have CR and LF stripped, so a handler cannot be tricked into splitting a response.

## Static files

`serve_dir(prefix, dir)` serves `res://` or `user://` directories. A `..` segment, backslash or colon is 403; a dotfile is 404; a directory serves `index.html`; files over `max_static_bytes` are refused. Percent-escapes are decoded before the check, so `%2e%2e` and `..%2f` are caught. The engine's `String.uri_decode()` silently drops a bad escape and an encoded NUL, which is why `DotHttpServer.percent_decode` exists and rejects both.

## TLS and secrets

Native TLS uses `TLSOptions.server(key, cert)` from two file paths (`start`'s last arguments or `cert`/`key` in the config dictionary). Contents are never accepted as strings, and a token or key is never read from environment or argv: `DotHttpServer.read_secret_file(path)` is the one way a host loads a token. The default is plain HTTP on loopback behind a reverse proxy that owns certificate renewal. A plain-text request at a TLS port gets no reply and the engine logs one `TLS handshake error` line.

## Tested

`examples/http_server_selftest` (8 sections, 63 checks): parser, routing, every limit, traversal, JSON and header injection, malformed input, a `DotHttp` client, and a real TLS handshake with a throwaway self-signed certificate.
