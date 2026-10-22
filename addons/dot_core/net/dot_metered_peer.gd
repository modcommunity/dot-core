class_name DotMeteredPeer
extends MultiplayerPeerExtension

## Any [MultiplayerPeer], counted: bytes and packets each way, per channel, plus what the
## transport underneath can say about itself.
##
## [codeblock]
## var created := transport.create_client(address)
## multiplayer.multiplayer_peer = DotMeteredPeer.wrap(created.value)
## # ...
## var peer := multiplayer.multiplayer_peer as DotMeteredPeer
## peer.bytes_in, peer.bytes_in_by_channel[DotTransport.Channel.STATE], peer.rtt_ms
## [/codeblock]
##
## [b]Why a wrapper, and not the transport's own numbers.[/b] ENet keeps byte totals for its
## host and WebSocket keeps none, and a browser is a WebSocket client: a graph that read the
## transport would be empty for most of the people who would open it. Every packet passes
## through [method _put_packet_script] and [method _poll] here whichever transport is under
## it, so the counts are the same thing on both. What only one of them knows (ENet's loss and
## round-trip variance, a WebSocket's unsent backlog) is in [method transport_stats], and
## labelled as such rather than faked on the other.
##
## [b]Payload bytes, not wire bytes.[/b] What is counted is what [SceneMultiplayer] handed
## down and got back: RPC headers included, the transport's own framing (ENet's, a
## WebSocket frame, IP and UDP) not. That is the part a game can change, so it is the part
## worth graphing; a number that also moved with the transport would hide the game's own
## change inside it.
##
## [b]Totals, never rates.[/b] A rate has a window, and the right window is whoever is
## reading's: a graph wants a bar per twentieth of a second, a scoreboard a number per
## second. This keeps monotonic totals and the reader differences them, so two readers never
## fight over one window — the bug [DotNetStats] had with its rolling rates.
##
## Incoming packets are drained into a queue on [method _poll], the way [DotDualPeer] does
## it, because [SceneMultiplayer] asks for a packet's sender, channel and mode around the
## call that pops it, and a pass-through would describe the packet behind it.
##
## No ENet identifier is named in this file: the web template has none, and a script
## mentioning one does not compile there. ENet is reached by [method Object.call].

## The peer underneath. Everything is forwarded to it.
var inner: MultiplayerPeer = null

var bytes_in: int = 0
var bytes_out: int = 0
var packets_in: int = 0
var packets_out: int = 0

## Indexed by channel number. Grown on demand, so a game that sends on channel 6 is counted
## rather than dropped; see [constant DotTransport.CHANNEL_COUNT] for the family's four.
var bytes_in_by_channel: PackedInt64Array = PackedInt64Array([0, 0, 0, 0])
var bytes_out_by_channel: PackedInt64Array = PackedInt64Array([0, 0, 0, 0])

## The largest packet received, in bytes. A packet near the transport's limit is a
## snapshot that is about to be split or refused.
var largest_in: int = 0

## Round trip in milliseconds as the application measured it ([method note_rtt]); -1 is
## not measured yet. ENet measures its own continuously, and [method rtt] prefers it.
var rtt_ms: float = -1.0

## How far apart the application's recent round trips are, in milliseconds: the mean
## absolute difference between consecutive samples, which is what a player feels as jitter.
var rtt_jitter_ms: float = 0.0

## What the other end said about itself, as it said it (a server's frame rate, its tick).
## Opaque here: [method note_remote] stores and a reader interprets.
var remote: Dictionary = {}

## When [member remote] last changed, in [method Time.get_ticks_msec].
var remote_at_ms: int = 0

var _queue: Array[Dictionary] = []
var _current: Dictionary = {}
var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _closed := false


## [param peer] behind a meter. A peer that is already one is returned as it is, so a
## caller that wraps twice counts once.
static func wrap(peer: MultiplayerPeer) -> MultiplayerPeer:
	if peer == null or peer is DotMeteredPeer:
		return peer
	var m := DotMeteredPeer.new()
	m.inner = peer
	# Methods, not lambdas: a lambda capturing [code]m[/code] would be held by the inner
	# peer's signal and hold [code]m[/code], which holds the inner peer — a cycle between
	# two RefCounted objects, and neither socket would ever be freed. A Callable bound to
	# a method holds the object by id.
	peer.peer_connected.connect(m._on_inner_connected)
	peer.peer_disconnected.connect(m._on_inner_disconnected)
	return m


func _on_inner_connected(id: int) -> void:
	peer_connected.emit(id)


func _on_inner_disconnected(id: int) -> void:
	peer_disconnected.emit(id)


## The meter behind [param peer], or null when it is not one. For a reader that holds a
## [MultiplayerAPI] and must not assume.
static func of(peer: Object) -> DotMeteredPeer:
	return peer as DotMeteredPeer if peer is DotMeteredPeer else null


# --- What the application tells it ---------------------------------------------

## A round trip the application measured (a heartbeat echoed back).
func note_rtt(ms: float) -> void:
	if ms < 0.0:
		return
	if rtt_ms >= 0.0:
		# Smoothed the way TCP smooths its own variance (RFC 6298's 1/4), so one late
		# heartbeat moves the number without becoming it.
		rtt_jitter_ms = lerpf(rtt_jitter_ms, absf(ms - rtt_ms), 0.25)
	rtt_ms = ms


## What the other end reported about itself. Replaces what was there.
func note_remote(info: Dictionary) -> void:
	remote = info.duplicate(true)
	remote_at_ms = Time.get_ticks_msec()


# --- Reading -------------------------------------------------------------------

## "enet", "websocket", or the inner peer's class.
func transport_name() -> String:
	if inner == null:
		return ""
	var cls := inner.get_class()
	if cls.begins_with("ENet"):
		return "enet"
	if cls.begins_with("WebSocket"):
		return "websocket"
	return cls


## The round trip worth showing: the transport's own where it keeps one (ENet times every
## acknowledged packet), else the application's. -1 when neither has measured.
func rtt() -> float:
	var t := transport_stats()
	if float(t.get("rtt_ms", 0.0)) > 0.0:
		return float(t["rtt_ms"])
	return rtt_ms


## What the transport underneath knows about the link to the server, and only what it
## really knows:
## - ENet: [code]rtt_ms[/code], [code]rtt_var_ms[/code], [code]loss[/code] (0..1, ENet's own
##   running mean), [code]throttle[/code] (0..1, how far ENet has backed its unreliable
##   sends off).
## - WebSocket: [code]queued[/code], bytes accepted and not yet sent — the backlog that,
##   on a reliable stream, is what loss turns into.
## Empty for anything else, and for a server (which has a link per client, not one).
func transport_stats() -> Dictionary:
	if inner == null or not inner.has_method(&"get_peer"):
		return {}
	var link: Object = inner.call(&"get_peer", 1)
	if link == null:
		return {}

	if link.has_method(&"get_statistic") and ClassDB.class_exists(&"ENetPacketPeer"):
		var c := func(n: StringName) -> int: return ClassDB.class_get_integer_constant(&"ENetPacketPeer", n)
		var scale := float(maxi(1, c.call(&"PACKET_LOSS_SCALE")))
		var throttle_scale := float(maxi(1, c.call(&"PACKET_THROTTLE_SCALE")))
		return {
			"rtt_ms": float(link.call(&"get_statistic", c.call(&"PEER_ROUND_TRIP_TIME"))),
			"rtt_var_ms": float(link.call(&"get_statistic", c.call(&"PEER_ROUND_TRIP_TIME_VARIANCE"))),
			"loss": clampf(float(link.call(&"get_statistic", c.call(&"PEER_PACKET_LOSS"))) / scale, 0.0, 1.0),
			"throttle": clampf(float(link.call(&"get_statistic", c.call(&"PEER_PACKET_THROTTLE"))) / throttle_scale, 0.0, 1.0),
		}

	if link.has_method(&"get_current_outbound_buffered_amount"):
		return {"queued": int(link.call(&"get_current_outbound_buffered_amount"))}

	return {}


## The inner peer's [code]get_peer[/code], so code that reads ENet's per-peer statistics by
## duck typing (a game measuring its own clock lead) keeps working behind the meter.
func get_peer(id: int) -> Object:
	if inner != null and inner.has_method(&"get_peer"):
		return inner.call(&"get_peer", id)
	return null


func reset() -> void:
	bytes_in = 0
	bytes_out = 0
	packets_in = 0
	packets_out = 0
	bytes_in_by_channel = PackedInt64Array([0, 0, 0, 0])
	bytes_out_by_channel = PackedInt64Array([0, 0, 0, 0])
	largest_in = 0


func describe() -> Dictionary:
	var d := {
		"transport": transport_name(),
		"bytes_in": bytes_in,
		"bytes_out": bytes_out,
		"packets_in": packets_in,
		"packets_out": packets_out,
		"bytes_in_by_channel": Array(bytes_in_by_channel),
		"bytes_out_by_channel": Array(bytes_out_by_channel),
		"largest_in": largest_in,
		"rtt_ms": rtt(),
		"rtt_jitter_ms": rtt_jitter_ms,
	}
	d.merge(transport_stats())
	if not remote.is_empty():
		d["remote"] = remote
	return d


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("transport %s" % transport_name())
	lines.append("in  %s in %d packets" % [DotPaths.format_bytes(bytes_in), packets_in])
	lines.append("out %s in %d packets" % [DotPaths.format_bytes(bytes_out), packets_out])
	for ch in maxi(bytes_in_by_channel.size(), bytes_out_by_channel.size()):
		lines.append("  channel %d: %s in, %s out" % [
			ch, DotPaths.format_bytes(_at(bytes_in_by_channel, ch)), DotPaths.format_bytes(_at(bytes_out_by_channel, ch)),
		])
	var r := rtt()
	lines.append("rtt %s" % ("%.0f ms" % r if r >= 0.0 else "not measured"))
	var t := transport_stats()
	for k in t:
		lines.append("%s %s" % [k, str(t[k])])
	return lines


static func _at(a: PackedInt64Array, i: int) -> int:
	return a[i] if i < a.size() else 0


static func _grow(a: PackedInt64Array, i: int) -> PackedInt64Array:
	if i >= a.size():
		var _r := a.resize(i + 1)
	return a


# --- MultiplayerPeerExtension ----------------------------------------------------

func _poll() -> void:
	if _closed or inner == null:
		return
	inner.poll()
	while inner.get_available_packet_count() > 0:
		# Described before it is popped: the inner peer describes the packet at the
		# FRONT of its queue, and popping first would describe the next one.
		var from := inner.get_packet_peer()
		var channel := inner.get_packet_channel()
		var mode := inner.get_packet_mode()
		var data := inner.get_packet()
		var size := data.size()
		bytes_in += size
		packets_in += 1
		largest_in = maxi(largest_in, size)
		if channel >= 0:
			bytes_in_by_channel = _grow(bytes_in_by_channel, channel)
			bytes_in_by_channel[channel] += size
		_queue.append({"data": data, "peer": from, "channel": channel, "mode": mode})


func _get_available_packet_count() -> int:
	return _queue.size()


func _get_packet_script() -> PackedByteArray:
	if _queue.is_empty():
		return PackedByteArray()
	_current = _queue.pop_front()
	return _current["data"]


func _get_packet_peer() -> int:
	if not _queue.is_empty():
		return int(_queue[0]["peer"])
	return int(_current.get("peer", 0))


func _get_packet_channel() -> int:
	if not _queue.is_empty():
		return int(_queue[0]["channel"])
	return int(_current.get("channel", 0))


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	if not _queue.is_empty():
		return _queue[0]["mode"]
	return _current.get("mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _closed or inner == null:
		return ERR_UNCONFIGURED
	inner.transfer_channel = _transfer_channel
	inner.transfer_mode = _transfer_mode
	inner.set_target_peer(_target_peer)
	var err := inner.put_packet(buffer)
	if err == OK:
		var size := buffer.size()
		bytes_out += size
		packets_out += 1
		bytes_out_by_channel = _grow(bytes_out_by_channel, _transfer_channel)
		bytes_out_by_channel[_transfer_channel] += size
	return err


func _get_max_packet_size() -> int:
	return inner.get_max_packet_size() if inner != null else 1 << 24


func _set_target_peer(peer: int) -> void:
	_target_peer = peer


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode


func _get_unique_id() -> int:
	return inner.get_unique_id() if inner != null else 0


func _is_server() -> bool:
	return inner != null and inner.get_unique_id() == 1


func _is_server_relay_supported() -> bool:
	return inner != null and inner.is_server_relay_supported()


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	if _closed or inner == null:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	return inner.get_connection_status()


func _set_refuse_new_connections(enable: bool) -> void:
	if inner != null:
		inner.refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return inner != null and inner.refuse_new_connections


func _disconnect_peer(peer: int, force: bool) -> void:
	if inner != null:
		inner.disconnect_peer(peer, force)


func _close() -> void:
	if _closed:
		return
	_closed = true
	if inner != null:
		inner.close()
	_queue.clear()
