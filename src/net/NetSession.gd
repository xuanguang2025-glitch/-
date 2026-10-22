extends Node
## The game's own way into a server.
##
## This file exists because of a gap that every green gate in Part 10 was hiding: the only thing
## that ever constructed a `MultiplayerClient` was `MPHarness`, and `MPHarness` was only ever
## called from `_mp_probe()` — which runs when you pass `--mp-probe` on the command line. So the
## server-priced build, the ledger-is-the-fact, the remote players were all real, all tested, and
## unreachable from the running game. A player who launched normally was always alone, always
## spending money that did not exist, and the HUD said so with a number nobody had earned.
##
## Three rules this file is built around, all of them straight from Part 10:
##
##   1. `balance_c` is only ever written from a byte the server sent. There is no local arithmetic
##      here at all — no "optimistic" decrement, no reconciliation. A predicted wallet is exactly
##      the "client is the authority" failure the spec forbids, and the ledger already answers
##      within one round trip.
##   2. `-1` means "the server has not told me yet", and it is rendered as such. Showing 0 would
##      be a different lie, and showing a default would be the old bug.
##   3. A failed join is kept, with its reason, and the HUD prints it. `connect_err` and
##      `disconnected(reason)` are stored, never swallowed.
##
## Deliberately not here: an account UI. The session token comes from the same backend login the
## save path already uses (`--backend=<url>`), so joining without a configured backend fails with
## that stated as the reason rather than inventing a second, unauthenticated way in.

signal balance_changed(cents: int)
signal state_changed(state: int)

const ST_OFFLINE := 0
const ST_CONNECTING := 1
const ST_ONLINE := 2
const ST_FAILED := 3

var state: int = ST_OFFLINE
## Why we are not online. Rendered verbatim; never cleared on success so the last real failure
## stays readable until something else overwrites it.
var detail := "未连接"
var balance_c := -1
var player_id := ""
var client: MultiplayerClient = null

var server_host := "127.0.0.1"
var server_port := 9876


func _ready() -> void:
	add_to_group("net_session")


## Points this session at a game server. Called by whoever knows the address (the boot args, or
## the menu once there is a field to type into) — not read from a constant, because a shipped
## client that can only ever dial localhost is not a client that can go online.
func set_endpoint(host: String, port: int) -> void:
	if not host.is_empty():
		server_host = host
	server_port = port


func is_online() -> bool:
	return state == ST_ONLINE


## One-line status for the menu button and the HUD. Never hides a failure behind "未连接":
## whatever went wrong is what gets shown.
func state_label() -> String:
	match state:
		ST_ONLINE:
			return "在线 %s  余额 %.2f 元" % [player_id, yuan()]
		ST_CONNECTING:
			return detail
		ST_FAILED:
			return detail
		_:
			return "未连接"


## Cents as the server stated them, or -1. Never derived.
func balance() -> int:
	return balance_c


func yuan() -> float:
	return float(balance_c) / 100.0 if balance_c >= 0 else -1.0


func toggle() -> bool:
	return leave() if client != null else join()


func join(host := "", port := -1) -> bool:
	if client != null:
		detail = "已经在线（%s）" % player_id
		return true
	if host.is_empty():
		host = server_host
	if port < 0:
		port = server_port
	var be = _backend()
	if be == null:
		state = ST_FAILED
		detail = "未配置后端（启动时加 --backend=<url>），拿不到 session token"
		state_changed.emit(state)
		return false
	var token := String(be.get("token"))
	if token.is_empty():
		state = ST_FAILED
		detail = "后端已连接但没有发回 session token（登录未完成）"
		state_changed.emit(state)
		return false

	server_host = host
	server_port = port
	state = ST_CONNECTING
	detail = "正在连接 %s:%d" % [host, port]
	state_changed.emit(state)

	# MPHarness is the single construction path on purpose: it is what decides that the client
	# joins the "multiplayer" group only after it is configured and wired to its presenter, and
	# routing placements at the wrong moment is how a client ends up asking a server that has not
	# authenticated it yet.
	var mp := MPHarness.attach(self, token, host, port)
	client = mp
	mp.connected.connect(_on_connected)
	mp.disconnected.connect(_on_disconnected)
	mp.econ_event.connect(_on_econ)
	if mp.connect_err != OK:
		state = ST_FAILED
		detail = "连接失败：%s（%s:%d）" % [error_string(mp.connect_err), host, port]
		state_changed.emit(state)
		_drop()
		return false
	return true


func leave() -> bool:
	_drop()
	state = ST_OFFLINE
	detail = "已断开"
	state_changed.emit(state)
	return true


func _drop() -> void:
	if client != null:
		client.queue_free()
	client = null
	player_id = ""


func _on_connected(id: String) -> void:
	player_id = id
	state = ST_ONLINE
	detail = "在线：%s" % id
	state_changed.emit(state)


func _on_disconnected(reason: String) -> void:
	state = ST_FAILED
	detail = "断开：%s" % reason
	state_changed.emit(state)
	_drop()


## The server's verdict on a transaction. `balance` is folded from the ledger server-side, so
## taking it verbatim is the whole point of this handler.
func _on_econ(ev: Dictionary) -> void:
	if not ev.has("balance"):
		return
	var b := int(ev["balance"])
	if b == balance_c:
		return
	balance_c = b
	balance_changed.emit(balance_c)


## The backend session lives on the creation system, which is in the "creation" group. Reached by
## group rather than by reference so this autoload has no compile-time edge to GameRoot.
func _backend():
	var c := get_tree().get_first_node_in_group("creation")
	return c.get("backend") if c != null else null
