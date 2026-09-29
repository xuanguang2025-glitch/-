class_name MultiplayerClient
extends Node
## Phase 176 / 177 / 186: the client side of the authoritative server.
##
## This node owns the socket to the game server, sends inputs on a fixed cadence, receives entity
## deltas and creation confirms, and runs the prediction/reconciliation loop that keeps local
## movement responsive while still deferring to the server's truth. Nothing here decides where a
## player *is* — that is the server's job — but without prediction the player would feel every
## round-trip as input lag, and no amount of server authority makes a game that feels broken worth
## playing.
##
## The transport is StreamPeerTCP, not ENet. That is not a preference: the Node game server has no
## dependency-free way to speak ENet, so the two ends previously sat on different protocols and
## never connected. TCP means every message is reliable and ordered, which is safe but pays
## head-of-line blocking on a lossy link — the real cost of this choice is recorded in KNOWN_ISSUES
## rather than argued away here.
##
## Creation commands are request/confirm: the client shows a ghost immediately for feedback,
## but the object only enters `CreationSystem.objects` when the server says it did. A malicious
## or buggy client cannot place buildings the server refused, because the server is the only
## thing that writes to the shared world state.

signal connected(player_id: String)
signal disconnected(reason: String)
signal creation_confirmed(req_id: String, obj_id: int)
signal creation_rejected(req_id: String, reason: String)
signal remote_creation(obj: Dictionary)
signal econ_event(ev: Dictionary)
signal entity_delta(entities: Array)
signal correction_applied(server_seq: int, error_m: float)

const SEND_HZ := 30
const RECONNECT_DELAY := 2.0
const PING_INTERVAL := 5.0
const MAX_FRAME := 1 << 20		# must match game_server.mjs's sanity cap
const RECON_SLACK_M := 2.0	# metres of per-sample overshoot tolerated before snapping

var sock: StreamPeerTCP
var session_id := ""
var player_id := ""
var auth_token := ""
var server_url := "127.0.0.1"
var server_port := 9876
var connect_err := -1		# Error code from the last connect_to_host attempt

## The last authoritative state the server sent for every other entity in interest range.
## Stored rather than dropped: a renderer that is not written yet is a known gap, but a client
## that throws away the server's truth has nothing left to render when it arrives.
var remote_entities: Dictionary = {}

var _rx := PackedByteArray()
var _handshaken := false
var _send_t := 0.0
var _ping_t := 0.0
var _input_seq := 0
var _last_server_seq := 0
var _last_server_pos := Vector2.ZERO
var _last_local_pos := Vector2.ZERO
var _first_state := true
var _reconnecting := false
var _grace_until := 0.0
var _self_error_m := 0.0
var _corrections := 0
var _rx_bytes := 0
var _rx_frames := 0
var _tx_bytes := 0
var _tx_frames := 0

var _pending_creations: Dictionary = {}
var _next_req_id := 0


func configure(token: String, url := "127.0.0.1", port := 9876) -> void:
	auth_token = token
	server_url = url
	server_port = port


func connect_to_server() -> void:
	if sock != null:
		return
	var s := StreamPeerTCP.new()
	# Recorded rather than swallowed: "the handshake timed out" is undiagnosable without knowing
	# whether connect() itself refused (Phase 233 rule 14).
	connect_err = s.connect_to_host(server_url, server_port)
	if connect_err != OK:
		# StreamPeerTCP is RefCounted: dropping the local is the release, free() would error.
		disconnected.emit("connect failed (%d)" % connect_err)
		return
	sock = s
	_first_state = true
	_reconnecting = false


func disconnect_from_server() -> void:
	if sock != null:
		sock.disconnect_from_host()
		sock = null
	_rx = PackedByteArray()
	_handshaken = false
	session_id = ""
	player_id = ""


func _process(delta: float) -> void:
	if sock == null:
		return
	# get_status() is a read of cached state — poll() is what drives the handshake and moves the
	# socket out of STATUS_CONNECTING. Without it the client sits "connecting" forever and never
	# reports an error, which is the worst possible failure mode for a network bug.
	sock.poll()
	match sock.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			if not _handshaken:
				_handshaken = true
				if session_id.is_empty():
					_send_hello()
				else:
					_send_reconnect()
			_pump_rx()
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			# A refused connect surfaces as STATUS_NONE here, not STATUS_ERROR: connect_to_host
			# leaves STATUS_CONNECTING and get_status() demotes it once the socket reports an error.
			# Treating NONE as "still connecting" turns a dead port into a silent 10-second wait.
			_on_disconnect("socket dead (status=%d)" % int(sock.get_status()))
		_:
			pass	# STATUS_CONNECTING: keep waiting

	_send_t += delta
	if _send_t >= 1.0 / SEND_HZ and _handshaken and not session_id.is_empty():
		_send_t = 0.0
		_send_input()

	_ping_t += delta
	if _ping_t >= PING_INTERVAL and _handshaken and not session_id.is_empty():
		_ping_t = 0.0
		_send(SyncProtocol.Msg.C2S_PING, {"t": Time.get_ticks_msec()}, SyncProtocol.Channel.RELIABLE)

	if _reconnecting and Time.get_unix_time_from_system() > _grace_until:
		_reconnecting = false
		connect_to_server()


## TCP is a byte stream, so a datagram boundary is not a message boundary: one read can return
## half a frame or six. Frames are [4-byte BE length][payload]; anything else is treated as a
## broken peer rather than resynchronised on a guess, because a desynced parser silently feeds
## garbage into the authority path.
func _pump_rx() -> void:
	var avail := sock.get_available_bytes()
	if avail > 0:
		# get_partial_data returns [Error, PackedByteArray] in this engine version, not a
		# Dictionary, and PackedByteArray has no big-endian accessor at all — the header is
		# assembled byte by byte so both ends agree on the same four bytes.
		var r: Array = sock.get_partial_data(avail)
		if int(r[0]) != OK:
			_on_disconnect("read failed")
			return
		_rx.append_array(r[1])
	while _rx.size() >= 4:
		var ln := (int(_rx[0]) << 24) | (int(_rx[1]) << 16) | (int(_rx[2]) << 8) | int(_rx[3])
		if ln <= 0 or ln > MAX_FRAME:
			_on_disconnect("bad frame length %d" % ln)
			return
		if _rx.size() < 4 + ln:
			return
		var body := _rx.slice(4, 4 + ln)
		_rx = _rx.slice(4 + ln)
		_count_rx(ln)
		_on_receive(body)


func _on_disconnect(reason: String) -> void:
	if sock != null:
		sock.disconnect_from_host()
		sock = null
	_handshaken = false
	_rx = PackedByteArray()
	if not _reconnecting and not session_id.is_empty():
		_reconnecting = true
		_grace_until = Time.get_unix_time_from_system() + RECONNECT_DELAY
		return
	disconnected.emit(reason)


func _on_receive(data: PackedByteArray) -> void:
	var decoded := SyncProtocol.decode(data)
	var msg: int = decoded["msg"]
	var p: Dictionary = decoded["payload"]
	match msg:
		SyncProtocol.Msg.S2C_WELCOME:
			player_id = String(p.get("player_id", ""))
			session_id = String(p.get("session_id", ""))
			_apply_snapshot(p.get("snapshot", {}))
			connected.emit(player_id)
		SyncProtocol.Msg.S2C_SNAPSHOT:
			_apply_snapshot(p)
		SyncProtocol.Msg.S2C_ENTITY_DELTA:
			_apply_entity_delta(p.get("entities", []))
		SyncProtocol.Msg.S2C_SELF_STATE:
			_apply_self_state(p)
		SyncProtocol.Msg.S2C_TIME:
			GameGlobals.set_time(float(p.get("hour", GameGlobals.time_of_day)))
			GameGlobals.set_weather(int(p.get("weather", GameGlobals.weather_kind)),
				float(p.get("wet", GameGlobals.weather_intensity)))
		SyncProtocol.Msg.S2C_CREATE_ACK:
			var rid := String(p.get("req_id", ""))
			if bool(p.get("ok", false)):
				creation_confirmed.emit(rid, int(p.get("obj_id", 0)))
			else:
				creation_rejected.emit(rid, String(p.get("reason", "")))
			_pending_creations.erase(rid)
		SyncProtocol.Msg.S2C_REMOVE_ACK:
			pass
		SyncProtocol.Msg.S2C_CREATION_STREAM:
			remote_creation.emit(p.get("obj", {}))
		SyncProtocol.Msg.S2C_ECON_EVENT:
			econ_event.emit(p)
		SyncProtocol.Msg.S2C_KICK:
			disconnected.emit("kicked: %s" % String(p.get("reason", "")))
			disconnect_from_server()
		SyncProtocol.Msg.S2C_PONG:
			pass


func _send_hello() -> void:
	_send(SyncProtocol.Msg.C2S_HELLO, {
		"token": auth_token,
		"client_version": SyncProtocol.PROTOCOL_VERSION,
	}, SyncProtocol.Channel.RELIABLE)


func _send_reconnect() -> void:
	_send(SyncProtocol.Msg.C2S_RECONNECT, {
		"session_id": session_id,
		"last_seq": _last_server_seq,
	}, SyncProtocol.Channel.RELIABLE)


func _send_input() -> void:
	var player_node := get_tree().get_first_node_in_group("player")
	if player_node == null:
		return
	var move_dir := Vector2.ZERO
	if Input.is_action_pressed("move_forward"):
		move_dir.y -= 1.0
	if Input.is_action_pressed("move_back"):
		move_dir.y += 1.0
	if Input.is_action_pressed("move_left"):
		move_dir.x -= 1.0
	if Input.is_action_pressed("move_right"):
		move_dir.x += 1.0
	if move_dir.length_squared() > 0.001:
		move_dir = move_dir.normalized()
	_input_seq += 1
	var yaw_val := 0.0
	if "yaw" in player_node:
		yaw_val = float(player_node.yaw)
	var payload := {
		"seq": _input_seq,
		"dt": get_process_delta_time(),
		"move_dir": move_dir,
		"yaw": yaw_val,
		"actions": 0,
	}
	_send(SyncProtocol.Msg.C2S_INPUT, payload, SyncProtocol.Channel.UNRELIABLE)


func request_create(tpl: String, x: float, z: float, yaw: float, scale: float,
		name := "", occ := -1) -> String:
	_next_req_id += 1
	var rid := "r_%d" % _next_req_id
	_pending_creations[rid] = {"tpl": tpl, "x": x, "z": z, "yaw": yaw,
		"scale": scale, "name": name, "occ": occ}
	_send(SyncProtocol.Msg.C2S_CREATE, {
		"req_id": rid, "tpl": tpl, "x": x, "z": z, "yaw": yaw,
		"scale": scale, "name": name, "occ": occ,
	}, SyncProtocol.Channel.RELIABLE)
	return rid


func request_remove(obj_id: int) -> String:
	_next_req_id += 1
	var rid := "r_%d" % _next_req_id
	_send(SyncProtocol.Msg.C2S_REMOVE, {"req_id": rid, "obj_id": obj_id},
		SyncProtocol.Channel.RELIABLE)
	return rid


## What the client actually knows, for the round-trip probe and the HUD.
func stats() -> Dictionary:
	return {"seq": _input_seq, "server_seq": _last_server_seq, "remote": remote_entities.size(),
		"corrections": _corrections, "error_m": _self_error_m,
		"status": -1 if sock == null else int(sock.get_status()),
		"server_x": _last_server_pos.x, "server_z": _last_server_pos.y,
		"rx_bytes": _rx_bytes, "rx_frames": _rx_frames, "tx_bytes": _tx_bytes,
		"tx_frames": _tx_frames}


## JSON is cheaper to be compatible with and more expensive on the wire; these counters make that
## trade a measured number in the pipeline log instead of an unquantified claim in a comment.
func _count_tx(n: int) -> void:
	_tx_bytes += n
	_tx_frames += 1


func _count_rx(n: int) -> void:
	_rx_bytes += n
	_rx_frames += 1


func _apply_snapshot(snap: Dictionary) -> void:
	if typeof(snap) != TYPE_DICTIONARY:
		return
	if snap.has("hour"):
		GameGlobals.set_time(float(snap["hour"]))
	if snap.has("creations"):
		for c in snap["creations"]:
			remote_creation.emit(c)


func _apply_entity_delta(entities: Array) -> void:
	for e in entities:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var eid := String(e.get("id", ""))
		if eid.is_empty():
			continue
		remote_entities[eid] = e
	entity_delta.emit(entities)


## Phase 176 / 210 / 211: reconcile against the server's authoritative position for this client.
##
## The rule is a bound, not a metronome. Comparing absolute positions would snap the rig on every
## frame, because the server integrates `move_dir * dt * 6 m/s` while the local rig uses its own
## acceleration curve and is usually *behind* that — a client that moves less than allowed is
## correct, and dragging it backwards every tick would fight the animation for no security gain.
## So the client compares displacement since the last authoritative sample: if it moved further
## than the server moved, it moved in a way the server did not authorise, and that is the case
## worth snapping. A teleport is caught; a slow walk is not touched.
func _apply_self_state(p: Dictionary) -> void:
	_last_server_seq = int(p.get("seq", 0))
	var server_pos := Vector2(float(p.get("x", 0.0)), float(p.get("z", 0.0)))
	var rig := get_tree().get_first_node_in_group("player")
	if rig == null:
		_last_server_pos = server_pos
		return
	if _first_state:
		_first_state = false
		_last_server_pos = server_pos
		_last_local_pos = Vector2(rig.global_position.x, rig.global_position.z)
		return
	var local := Vector2(rig.global_position.x, rig.global_position.z)
	_self_error_m = _last_local_pos.distance_to(local) - _last_server_pos.distance_to(server_pos)
	if _self_error_m > RECON_SLACK_M:
		rig.global_position = Vector3(server_pos.x, rig.global_position.y, server_pos.y)
		_last_local_pos = server_pos
		_corrections += 1
		correction_applied.emit(_last_server_seq, _self_error_m)
	else:
		_last_local_pos = local
	_last_server_pos = server_pos


func _send(msg: int, payload: Dictionary, channel: int) -> void:
	if sock == null or sock.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var data := SyncProtocol.encode(msg, payload)
	# `channel` is carried for the contract test and for a future datagram transport; over TCP
	# every frame is reliable and ordered, so it cannot be honoured here. Silently dropping the
	# distinction would be the dishonest part, so it stays in the signature and in KNOWN_ISSUES.
	var n := data.size()
	var out := PackedByteArray()
	out.resize(4)
	out[0] = (n >> 24) & 0xFF
	out[1] = (n >> 16) & 0xFF
	out[2] = (n >> 8) & 0xFF
	out[3] = n & 0xFF
	# append_array adds to the end. Resizing to 4 + n first would leave n zero bytes between the
	# header and the payload and the server would parse those as the message.
	out.append_array(data)
	if sock.put_data(out) != OK:
		_on_disconnect("write failed")
	_count_tx(out.size())
