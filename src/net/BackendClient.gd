class_name BackendClient
extends Node
## Talks to the SOW backend for save persistence.
##
## Offline is a first-class state, not an error: the game always writes a local cache first
## and only then mirrors to the server, so a missing backend degrades to the pre-network
## behaviour instead of blocking the player. Money, level and ownership are never sent up -
## the server rejects them, and sending them would be a bug on our side.

const SAVE_VERSION := 2
const TIMEOUT := 4.0

var base := ""
var token := ""
var player_id := ""
var online := false
var last_error := ""


func configure(url: String) -> void:
	base = url.rstrip("/")
	online = base != ""


func _method_of(m: String) -> int:
	match m:
		"POST": return HTTPClient.METHOD_POST
		"PUT": return HTTPClient.METHOD_PUT
		"DELETE": return HTTPClient.METHOD_DELETE
		_: return HTTPClient.METHOD_GET


func _request(method: String, path: String, body: Dictionary) -> Dictionary:
	if not online:
		return {"status": 0, "json": {}, "error": "offline"}
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT
	add_child(req)
	var headers := ["Content-Type: application/json"]
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var payload := "" if body.is_empty() else JSON.stringify(body)
	# Godot 4.4 signature is request(url, headers, method, body) - there is no use_threads
	# argument like there was in 3.x.
	var err := req.request(base + path, PackedStringArray(headers),
		_method_of(method), payload)
	if err != OK:
		req.queue_free()
		last_error = "无法连接 %s" % base
		return {"status": 0, "json": {}, "error": last_error}
	var res: Array = await req.request_completed
	req.queue_free()
	var code := int(res[1])
	var parsed: Variant = {}
	# request_completed carries (result, http_code, headers, body) and body is a
	# PackedByteArray, not an Array - testing TYPE_ARRAY here silently dropped every reply.
	if res.size() > 3 and res[3] is PackedByteArray and not (res[3] as PackedByteArray).is_empty():
		parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		parsed = {}
	if code >= 400:
		last_error = String(parsed.get("error", "HTTP %d" % code))
	return {"status": code, "json": parsed, "error": "" if code < 400 else last_error}


## Establishes an identity. The secret is a generated device credential kept in user://, not
## a player-chosen password; real auth is a documented swap point in Docs/ARCHITECTURE.md.
func ensure_account(display_name: String, secret: String) -> bool:
	var r := await _request("POST", "/v1/accounts/login",
		{"display_name": display_name, "secret": secret})
	if r["status"] == 401 or r["status"] == 404:
		r = await _request("POST", "/v1/accounts",
			{"display_name": display_name, "secret": secret})
	var j: Dictionary = r["json"]
	if j.has("session_token"):
		token = String(j["session_token"])
		player_id = String(j["player_id"])
		last_error = ""
		return true
	last_error = String(r["error"])
	return false


func save(payload: Dictionary) -> bool:
	var r := await _request("PUT", "/v1/save",
		{"save_version": SAVE_VERSION, "payload": payload})
	if r["status"] != 200:
		last_error = String(r["error"])
		return false
	return true


## Returns {"ok", "recovered", "payload", "absent"}; absent means the server has nothing yet.
func load_save() -> Dictionary:
	var r := await _request("GET", "/v1/save", {})
	var code := int(r["status"])
	if code == 404:
		return {"ok": true, "absent": true, "recovered": false, "payload": {}}
	if code != 200:
		return {"ok": false, "absent": true, "recovered": false, "payload": {},
			"error": String(r["error"])}
	var j: Dictionary = r["json"]
	return {"ok": true, "absent": false, "recovered": bool(j.get("recovered", false)),
		"payload": j.get("payload", {})}


func balance() -> int:
	var r := await _request("GET", "/v1/me", {})
	return int((r["json"] as Dictionary).get("balance", -1))
