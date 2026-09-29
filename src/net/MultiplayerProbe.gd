class_name MultiplayerProbe
extends RefCounted
## Phase 234 / 176 / 210: drive the real Godot client against a live game server.
##
## server/multiplayer_test.mjs proves the server's rules to a Node client that reuses the server's
## own framing. That is not the same claim as "the game can play multiplayer", and the two were
## conflated for a while: the client spoke ENet and var_to_bytes, the server spoke TCP and msgpack,
## every Node-side assertion stayed green, and nothing had ever connected. Everything here can only
## pass by actually connecting, so it is the half that would have caught that.
##
## The teleport case is the point of the exercise. Phase 233 rule 1 forbids the client from being
## the authority on where it is, and a reconciliation rule that never fires proves nothing — so the
## probe deliberately breaks the rule and asserts the server puts the player back.


static func run(tree: SceneTree, mp: MultiplayerClient, rig: Node) -> int:
	var fails := 0
	var checks := 0
	print("=== multiplayer probe (real Godot client) ===")

	var welcomed := [false, ""]
	var lost := [false, ""]
	mp.connected.connect(func(pid: String) -> void:
		welcomed[0] = true
		welcomed[1] = pid)
	# Phase 233 rule 14: a handshake that fails because the server kicked us must not be reported
	# as a timeout. The reason is only ever visible on this signal.
	mp.disconnected.connect(func(reason: String) -> void:
		lost[0] = true
		lost[1] = reason)
	var confirmed := [false, 0]
	var rejected := [false, ""]
	mp.creation_confirmed.connect(func(_rid: String, obj_id: int) -> void:
		confirmed[0] = true
		confirmed[1] = obj_id)
	mp.creation_rejected.connect(func(_rid: String, reason: String) -> void:
		rejected[0] = true
		rejected[1] = reason)

	mp.connect_to_server()
	print("[mp] target %s:%d  connect=%d status=%d" % [
		mp.server_url, mp.server_port, mp.connect_err, int(mp.stats()["status"])])
	# The link can die between the two verdicts, and "timed out" would then describe a symptom
	# instead of the cause, so the handshake wait reports the link every second.
	var ticks := [0]
	var timed_out := not await _until(tree, func() -> bool:
		if welcomed[0] or lost[0]:
			return true
		ticks[0] += 1
		if ticks[0] % 60 == 0:
			var st: Dictionary = mp.stats()
			print("[mp] waiting: status=%d rx=%d tx=%d connect_err=%d" % [
				int(st["status"]), int(st["rx_frames"]), int(st["tx_frames"]), mp.connect_err])
		return false, 10000)
	if timed_out:
		fails += _that("客户端与服务器完成握手", false,
			"10 秒内无进展（status=%d）：服务器未接受 TCP 连接" % int(mp.stats()["status"]))
		checks += 1
		print("=== multiplayer probe: FAIL (%d/%d) ===" % [fails, checks])
		return fails
	if lost[0] and not welcomed[0]:
		fails += _that("客户端与服务器完成握手", false, "服务器断开：%s" % String(lost[1]))
		print("=== multiplayer probe: FAIL (%d/%d) ===" % [fails, 1])
		return fails
	fails += _that("客户端与服务器完成握手", true)
	checks += 1
	fails += _that("服务器发回 player_id", String(welcomed[1]).length() > 3, String(welcomed[1]))
	checks += 1

	# Idle: the server integrates its own movement model while the rig stands still, so a rule that
	# compared absolute positions would snap here. Zero corrections while doing nothing is what
	# separates "the server bounds the client" from "the server fights the client".
	await _for(tree, 1.5)
	var s0: Dictionary = mp.stats()
	fails += _that("空闲时收到服务器权威位置", int(s0["server_seq"]) >= 0 and int(s0["rx_frames"]) > 5,
		"rx_frames=%d server_seq=%d" % [int(s0["rx_frames"]), int(s0["server_seq"])])
	checks += 1
	fails += _that("正常站立不被回弹", int(s0["corrections"]) == 0, "corrections=%d" % int(s0["corrections"]))
	checks += 1

	# Cheat: move the local rig without the server's authorisation, which is exactly what a
	# teleporter does. The bound must catch it and put the player where the server thinks they are.
	var before: Vector3 = rig.global_position
	rig.global_position = before + Vector3(240.0, 0.0, 0.0)
	var snapped: bool = await _until(tree,
		func() -> bool: return int(mp.stats()["corrections"]) > 0, 4000)
	var s1: Dictionary = mp.stats()
	fails += _that("未经授权的位移被服务器回弹", snapped, "corrections=%d" % int(s1["corrections"]))
	checks += 1
	var back := Vector2(rig.global_position.x, rig.global_position.z).distance_to(
		Vector2(float(s1["server_x"]), float(s1["server_z"])))
	fails += _that("回弹后位置服从服务器", snapped and back < 1.0, "偏差 %.2f m" % back)
	checks += 1

	# Server-authoritative creation, both directions: a legal placement is accepted with a server
	# object id, and a placement in the Huangpu is refused. The client's own validator is not in
	# this path — the answer has to come from the process that owns the world.
	mp.request_create("mall", 2000.0, 2000.0, 0.0, 1.0)
	if await _until(tree, func() -> bool: return confirmed[0], 6000):
		fails += _that("合法放置被服务器接受", int(confirmed[1]) > 0, "obj_id=%d" % int(confirmed[1]))
	else:
		fails += _that("合法放置被服务器接受", false, "没有收到 CREATE_ACK")
	checks += 1

	await _for(tree, 0.3)
	confirmed[0] = false
	mp.request_create("mall", 0.0, 0.0, 0.0, 1.0)
	if await _until(tree, func() -> bool: return rejected[0], 6000):
		fails += _that("黄浦江里的放置被服务器拒绝", String(rejected[1]).length() > 0,
			String(rejected[1]))
	else:
		fails += _that("黄浦江里的放置被服务器拒绝", false, "竟然被接受")
	checks += 1

	var s2: Dictionary = mp.stats()
	print("[mp] 上行 %d 帧 / %d B   下行 %d 帧 / %d B   下行均帧 %.1f B" % [
		int(s2["tx_frames"]), int(s2["tx_bytes"]), int(s2["rx_frames"]), int(s2["rx_bytes"]),
		float(s2["rx_bytes"]) / maxf(float(s2["rx_frames"]), 1.0)])
	mp.disconnect_from_server()
	print("=== multiplayer probe: %s (%d/%d) ===" % [
		"PASS" if fails == 0 else "FAIL", checks - fails, checks])
	return fails


static func _that(label: String, cond: bool, detail := "") -> int:
	if cond:
		print("PASS  %s" % label)
		return 0
	print("FAIL  %s  %s" % [label, detail])
	return 1


static func _until(tree: SceneTree, cond: Callable, ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await tree.process_frame
	return cond.call()


static func _for(tree: SceneTree, seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
