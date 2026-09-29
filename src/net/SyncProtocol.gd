class_name SyncProtocol
extends RefCounted
## Phase 175 / 227: the wire contract between client and game server.
##
## Every multiplayer bug eventually traces back to "the two sides disagreed on what this byte
## sequence meant". So the protocol lives in one file, with explicit message ids and field
## orders, and both the Godot client and the Node game server import the same table.
##
## The encoding is JSON, and that is a concession rather than a preference: Godot has no MessagePack
## and the Node side must stay dependency-free, so the only format both ends can decode without a
## plugin is JSON. The previous revision of this paragraph claimed msgpack was "natively supported
## by both runtimes" — it is not, the client really emitted var_to_bytes, the server really parsed
## msgpack, and the two never once connected. Frame: [4-byte big-endian length][UTF-8 JSON array]
## whose element 0 is the message id.
##
## Reliable vs unreliable is a property of the *channel*, not the message. Movement ticks belong on
## an unreliable channel because a late position is worse than a missing one; creation commands and
## economy events belong on a reliable channel because they must arrive exactly once. The transport
## is currently TCP, which is reliable and ordered for everything, so CHANNEL_OF is advisory: it is
## what a datagram transport would use, and the contract test checks the table, but it does not yet
## change on-the-w behaviour. KNOWN_ISSUES records that gap instead of this comment hiding it.

enum Msg {
	# --- Handshake (reliable) -------------------------------------------------
	C2S_HELLO        = 1,   # {token, client_version}
	S2C_WELCOME      = 2,   # {player_id, session_id, snapshot}
	C2S_RECONNECT    = 3,   # {session_id, last_seq}
	S2C_SNAPSHOT     = 4,   # full world state for reconnect / initial sync

	# --- Per-tick (unreliable) ------------------------------------------------
	C2S_INPUT        = 10,  # {seq, dt, move_dir, yaw, actions}
	S2C_ENTITY_DELTA = 11,  # [{id, kind, x, z, yaw}]
	S2C_TIME         = 12,  # {hour, day, weather, wet}
	# The server's authoritative position for *this* client, tagged with the input sequence it was
	# computed from. Without this there is nothing to reconcile against: the client would be
	# trusting its own prediction, which is exactly the authority Phase 173 forbids.
	S2C_SELF_STATE   = 13,  # {seq, x, z, yaw}

	# --- Creation (reliable) --------------------------------------------------
	C2S_CREATE       = 20,  # {req_id, tpl, x, z, yaw, scale, name?, occ?}
	C2S_REMOVE       = 21,  # {req_id, obj_id}
	S2C_CREATE_ACK   = 22,  # {req_id, ok, obj_id?, reason?}
	S2C_REMOVE_ACK   = 23,  # {req_id, ok, reason?}
	S2C_CREATION_STREAM = 24,  # {obj} — other players' confirmed creations

	# --- Economy (reliable) ---------------------------------------------------
	S2C_ECON_EVENT   = 30,  # {kind, district, delta_jobs, delta_shops, money_total}

	# --- Session (reliable) ---------------------------------------------------
	S2C_KICK         = 40,  # {reason}
	C2S_PING         = 41,  # {t}
	S2C_PONG         = 42,  # {t}
}

enum Channel {
	RELIABLE   = 0,
	UNRELIABLE = 1,
}

## Which channel a message type travels on. Anything not listed is treated as reliable so a
## new message type cannot accidentally end up on the lossy channel.
const CHANNEL_OF := {
	Msg.C2S_HELLO: Channel.RELIABLE,
	Msg.S2C_WELCOME: Channel.RELIABLE,
	Msg.C2S_RECONNECT: Channel.RELIABLE,
	Msg.S2C_SNAPSHOT: Channel.RELIABLE,
	Msg.C2S_INPUT: Channel.UNRELIABLE,
	Msg.S2C_ENTITY_DELTA: Channel.UNRELIABLE,
	Msg.S2C_TIME: Channel.UNRELIABLE,
	Msg.S2C_SELF_STATE: Channel.UNRELIABLE,
	Msg.C2S_CREATE: Channel.RELIABLE,
	Msg.C2S_REMOVE: Channel.RELIABLE,
	Msg.S2C_CREATE_ACK: Channel.RELIABLE,
	Msg.S2C_REMOVE_ACK: Channel.RELIABLE,
	Msg.S2C_CREATION_STREAM: Channel.RELIABLE,
	Msg.S2C_ECON_EVENT: Channel.RELIABLE,
	Msg.S2C_KICK: Channel.RELIABLE,
	Msg.C2S_PING: Channel.RELIABLE,
	Msg.S2C_PONG: Channel.RELIABLE,
}

const PROTOCOL_VERSION := 1


static func channel_for(msg: int) -> int:
	return int(CHANNEL_OF.get(msg, Channel.RELIABLE))


## Encode [msg_id, ...fields] into a PackedByteArray. The decoder on the other side reads the
## first element as the message id and dispatches; everything after is message-specific.
static func encode(msg: int, payload: Dictionary) -> PackedByteArray:
	var arr := [msg]
	match msg:
		Msg.C2S_HELLO:
			arr.append(String(payload.get("token", "")))
			arr.append(int(payload.get("client_version", PROTOCOL_VERSION)))
		Msg.S2C_WELCOME:
			arr.append(String(payload.get("player_id", "")))
			arr.append(String(payload.get("session_id", "")))
			arr.append(payload.get("snapshot", {}))
		Msg.C2S_RECONNECT:
			arr.append(String(payload.get("session_id", "")))
			arr.append(int(payload.get("last_seq", 0)))
		Msg.S2C_SNAPSHOT:
			arr.append(payload)
		Msg.C2S_INPUT:
			arr.append(int(payload.get("seq", 0)))
			arr.append(float(payload.get("dt", 0.0)))
			var md: Vector2 = payload.get("move_dir", Vector2.ZERO)
			arr.append(float(md.x))
			arr.append(float(md.y))
			arr.append(float(payload.get("yaw", 0.0)))
			arr.append(int(payload.get("actions", 0)))
		Msg.S2C_ENTITY_DELTA:
			arr.append(payload.get("entities", []))
		Msg.S2C_TIME:
			arr.append(float(payload.get("hour", 0.0)))
			arr.append(int(payload.get("day", 1)))
			arr.append(int(payload.get("weather", 0)))
			arr.append(float(payload.get("wet", 0.0)))
		Msg.S2C_SELF_STATE:
			arr.append(int(payload.get("seq", 0)))
			arr.append(float(payload.get("x", 0.0)))
			arr.append(float(payload.get("z", 0.0)))
			arr.append(float(payload.get("yaw", 0.0)))
		Msg.C2S_CREATE:
			arr.append(String(payload.get("req_id", "")))
			arr.append(String(payload.get("tpl", "")))
			arr.append(float(payload.get("x", 0.0)))
			arr.append(float(payload.get("z", 0.0)))
			arr.append(float(payload.get("yaw", 0.0)))
			arr.append(float(payload.get("scale", 1.0)))
			arr.append(String(payload.get("name", "")))
			arr.append(int(payload.get("occ", -1)))
		Msg.C2S_REMOVE:
			arr.append(String(payload.get("req_id", "")))
			arr.append(int(payload.get("obj_id", 0)))
		Msg.S2C_CREATE_ACK:
			arr.append(String(payload.get("req_id", "")))
			arr.append(bool(payload.get("ok", false)))
			arr.append(int(payload.get("obj_id", 0)))
			arr.append(String(payload.get("reason", "")))
		Msg.S2C_REMOVE_ACK:
			arr.append(String(payload.get("req_id", "")))
			arr.append(bool(payload.get("ok", false)))
			arr.append(String(payload.get("reason", "")))
		Msg.S2C_CREATION_STREAM:
			arr.append(payload.get("obj", {}))
		Msg.S2C_ECON_EVENT:
			arr.append(payload)
		Msg.S2C_KICK:
			arr.append(String(payload.get("reason", "")))
		Msg.C2S_PING:
			arr.append(int(payload.get("t", 0)))
		Msg.S2C_PONG:
			arr.append(int(payload.get("t", 0)))
		_:
			arr.append(payload)
	# full_precision: a truncated yaw or position turns reconciliation into a permanent 1e-3
	# disagreement between two peers that are actually agreeing.
	return JSON.stringify(arr, "", false, true).to_utf8_buffer()


static func decode(data: PackedByteArray) -> Dictionary:
	var arr = JSON.parse_string(data.get_string_from_utf8())
	if typeof(arr) != TYPE_ARRAY or arr.size() < 1:
		return {"msg": -1, "payload": {}}
	var msg: int = int(arr[0])
	var p := {}
	match msg:
		Msg.C2S_HELLO:
			p["token"] = String(arr[1]) if arr.size() > 1 else ""
			p["client_version"] = int(arr[2]) if arr.size() > 2 else 0
		Msg.S2C_WELCOME:
			p["player_id"] = String(arr[1]) if arr.size() > 1 else ""
			p["session_id"] = String(arr[2]) if arr.size() > 2 else ""
			p["snapshot"] = arr[3] if arr.size() > 3 else {}
		Msg.C2S_RECONNECT:
			p["session_id"] = String(arr[1]) if arr.size() > 1 else ""
			p["last_seq"] = int(arr[2]) if arr.size() > 2 else 0
		Msg.S2C_SNAPSHOT:
			p = arr[1] if arr.size() > 1 else {}
		Msg.C2S_INPUT:
			p["seq"] = int(arr[1]) if arr.size() > 1 else 0
			p["dt"] = float(arr[2]) if arr.size() > 2 else 0.0
			p["move_dir"] = Vector2(float(arr[3]) if arr.size() > 3 else 0.0,
				float(arr[4]) if arr.size() > 4 else 0.0)
			p["yaw"] = float(arr[5]) if arr.size() > 5 else 0.0
			p["actions"] = int(arr[6]) if arr.size() > 6 else 0
		Msg.S2C_ENTITY_DELTA:
			p["entities"] = arr[1] if arr.size() > 1 else []
		Msg.S2C_SELF_STATE:
			p["seq"] = int(arr[1]) if arr.size() > 1 else 0
			p["x"] = float(arr[2]) if arr.size() > 2 else 0.0
			p["z"] = float(arr[3]) if arr.size() > 3 else 0.0
			p["yaw"] = float(arr[4]) if arr.size() > 4 else 0.0
		Msg.S2C_TIME:
			p["hour"] = float(arr[1]) if arr.size() > 1 else 0.0
			p["day"] = int(arr[2]) if arr.size() > 2 else 1
			p["weather"] = int(arr[3]) if arr.size() > 3 else 0
			p["wet"] = float(arr[4]) if arr.size() > 4 else 0.0
		Msg.C2S_CREATE:
			p["req_id"] = String(arr[1]) if arr.size() > 1 else ""
			p["tpl"] = String(arr[2]) if arr.size() > 2 else ""
			p["x"] = float(arr[3]) if arr.size() > 3 else 0.0
			p["z"] = float(arr[4]) if arr.size() > 4 else 0.0
			p["yaw"] = float(arr[5]) if arr.size() > 5 else 0.0
			p["scale"] = float(arr[6]) if arr.size() > 6 else 1.0
			p["name"] = String(arr[7]) if arr.size() > 7 else ""
			p["occ"] = int(arr[8]) if arr.size() > 8 else -1
		Msg.C2S_REMOVE:
			p["req_id"] = String(arr[1]) if arr.size() > 1 else ""
			p["obj_id"] = int(arr[2]) if arr.size() > 2 else 0
		Msg.S2C_CREATE_ACK:
			p["req_id"] = String(arr[1]) if arr.size() > 1 else ""
			p["ok"] = bool(arr[2]) if arr.size() > 2 else false
			p["obj_id"] = int(arr[3]) if arr.size() > 3 else 0
			p["reason"] = String(arr[4]) if arr.size() > 4 else ""
		Msg.S2C_REMOVE_ACK:
			p["req_id"] = String(arr[1]) if arr.size() > 1 else ""
			p["ok"] = bool(arr[2]) if arr.size() > 2 else false
			p["reason"] = String(arr[3]) if arr.size() > 3 else ""
		Msg.S2C_CREATION_STREAM:
			p["obj"] = arr[1] if arr.size() > 1 else {}
		Msg.S2C_ECON_EVENT:
			p = arr[1] if arr.size() > 1 else {}
		Msg.S2C_KICK:
			p["reason"] = String(arr[1]) if arr.size() > 1 else ""
		Msg.C2S_PING:
			p["t"] = int(arr[1]) if arr.size() > 1 else 0
		Msg.S2C_PONG:
			p["t"] = int(arr[1]) if arr.size() > 1 else 0
		_:
			p["raw"] = arr.slice(1)
	return {"msg": msg, "payload": p}
