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


static func run(tree: SceneTree, host: Node, rig: Player, mp: MultiplayerClient,
		layer: RemoteAvatarLayer, backend_url: String, shot_path := "") -> int:
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
	# Every economic number this file asserts on comes from the server's own event stream. Reading
	# a locally-computed balance would prove nothing about who is authoritative (Phase 196).
	var econ := []
	mp.econ_event.connect(func(ev: Dictionary) -> void:
		econ.append(ev))

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

	# --- a second real client, so replication has something to replicate ---------------------
	# Everything above is single-player-with-a-server: it would pass with no other human present.
	# These four are the ones that answer Phase 234's "they can see each other", and they need a
	# second account because the server keys players by player_id — one account is one player.
	var peer := await _connect_peer(tree, host, backend_url, mp.server_url, mp.server_port)
	fails += _that("第二个真实客户端以另一账号连入",
		peer != null and not peer.player_id.is_empty())
	checks += 1
	if peer != null:
		var pid := String(peer.player_id)
		var appeared := await _until(tree, func() -> bool: return layer.avatar_count() > 0, 6000)
		fails += _that("对端玩家被实例化为可见节点", appeared,
			"avatars=%d remote=%d" % [layer.avatar_count(), mp.remote_entities.size()])
		checks += 1
		var start := Vector2.ZERO
		var av0: Node3D = layer.avatar_of(pid)
		if av0 != null:
			start = Vector2(av0.position.x, av0.position.z)
		# Driven by wall clock, not frame count: a headless build can run hundreds of frames a
		# second, and a fixed number of inputs would move the peer a distance that depends on FPS.
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 2500:
			peer.send_move(Vector2(0.0, -1.0), 0.0)
			await tree.process_frame
		var moved := 0.0
		var av1: Node3D = layer.avatar_of(pid)
		if av1 != null:
			moved = start.distance_to(Vector2(av1.position.x, av1.position.z))
		fails += _that("对端节点随服务器复制而移动", moved > 2.0, "%.2f m" % moved)
		checks += 1
		if av1 != null:
			# Steer the peer to a point directly ahead of the local camera instead of rotating the
			# local player: deriving "ahead" from the camera's own basis is convention-free, while
			# solving for a yaw meant guessing how Player.gd maps yaw to a facing direction, and the
			# first guess was wrong in a way that looked like a replication failure. Distance matters
			# too — the camera's far plane is 100 m and the two spawn points are further apart.
			var cam: Camera3D = rig.camera
			var aim := Vector3.ZERO
			if cam != null:
				var flat := -cam.global_transform.basis.z
				flat.y = 0.0
				aim = cam.global_position + flat.normalized() * 16.0
			var gap := 9999.0
			var steps := 0
			while gap > 3.0 and steps < 1500:
				steps += 1
				var cur: Dictionary = mp.remote_entities.get(pid, {})
				if cur.is_empty():
					break
				var px := float(cur.get("x", 0.0))
				var pz := float(cur.get("z", 0.0))
				gap = Vector2(aim.x - px, aim.z - pz).length()
				# move_dir.x drives world x and move_dir.y drives world z — the server's convention,
				# read off its own integration rather than assumed here.
				peer.send_move(Vector2(aim.x - px, aim.z - pz), 0.0, 0.2)
				await tree.process_frame
			var near: Dictionary = mp.remote_entities.get(pid, {})
			fails += _that("对端可被驱动到相机正前方", near != null and gap <= 3.0,
				"%.1f m / %d 步" % [gap, steps])
			checks += 1
			# "A node exists" is not the claim Phase 234 makes; being inside the local camera's
			# frustum at the replicated coordinates is the testable half of "you can see each other".
			var av2: Node3D = layer.avatar_of(pid) if cam != null else null
			var chest := Vector3.ZERO
			if av2 != null:
				chest = av2.global_position + Vector3(0.0, 1.1, 0.0)
			fails += _that("对端玩家位于本地相机视锥内",
				av2 != null and cam.is_position_in_frustum(chest),
				"节点 %s 胸口 %s" % ["有" if av2 != null else "无", str(chest)])
			checks += 1
			if not shot_path.is_empty() and cam != null:
				await tree.process_frame
				var img := host.get_viewport().get_texture().get_image()
				if img != null:
					var serr := img.save_png(shot_path)
					print("[mp] 截图 %s err=%d" % [shot_path, serr])
		# Walking out of interest range is the despawn path worth proving. Disconnecting is *not*:
		# Phase 209 says a dropped player stays in the world for the grace period, so an avatar that
		# survives a socket close is correct behaviour and asserting otherwise would encode a bug.
		var left := 0
		while layer.avatar_count() > 0 and left < 900:
			left += 1
			peer.send_move(Vector2(0.0, -1.0), 0.0, 0.2)
			await tree.process_frame
		fails += _that("对端离开兴趣范围后节点被回收", layer.avatar_count() == 0,
			"走了 %d 步仍在 %d 个" % [left, layer.avatar_count()])
		checks += 1
		peer.disconnect_from_server()

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
	# Cheat: hold the local rig at a position the server never authorised, which is what a
	# teleporter actually does — a single assignment would be undone by the next physics frame
	# before the server's next sample arrived, and the test would then be measuring whether the
	# rig got stuck on a building rather than whether the authority bound works.
	var before: Vector3 = rig.global_position
	var forced := before + Vector3(240.0, 0.0, 0.0)
	var t_cheat := Time.get_ticks_msec()
	var snapped := false
	while not snapped and Time.get_ticks_msec() - t_cheat < 4000:
		rig.global_position = forced
		await tree.process_frame
		snapped = int(mp.stats()["corrections"]) > 0
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

	var build_ev: Dictionary = {}
	for ev in econ:
		if String(ev.get("kind", "")) == "build":
			build_ev = ev
			break
	fails += _that("真实客户端收到服务器给出的经济后果", not build_ev.is_empty(),
		"econ=%d" % econ.size())
	checks += 1
	# 1000 signup grant minus the 600 the server charges for a mall. Asserting the exact number is
	# the point: it can only come out right if the client displayed the ledger's fold rather than
	# anything it computed itself (Phase 196 rule 2).
	fails += _that("扣款额与余额都来自服务器账本",
		int(build_ev.get("delta", 0)) == -600 and int(build_ev.get("balance", -1)) == 400,
		str(build_ev))
	checks += 1

	var s2: Dictionary = mp.stats()
	print("[mp] 上行 %d 帧 / %d B   下行 %d 帧 / %d B   下行均帧 %.1f B" % [
		int(s2["tx_frames"]), int(s2["tx_bytes"]), int(s2["rx_frames"]), int(s2["rx_bytes"]),
		float(s2["rx_bytes"]) / maxf(float(s2["rx_frames"]), 1.0)])
	mp.disconnect_from_server()
	print("=== multiplayer probe: %s (%d/%d) ===" % [
		"PASS" if fails == 0 else "FAIL", checks - fails, checks])
	return fails


## A second client with its own account, connected through the same gateway and game server the
## main client uses. Returns null (and says why) rather than silently skipping the assertions that
## depend on it — a skipped replication check is how "two players see each other" stays unproven.
static func _connect_peer(tree: SceneTree, host: Node, backend_url: String,
		url: String, port: int) -> MultiplayerClient:
	var be := BackendClient.new()
	be.name = "PeerBackend"
	host.add_child(be)
	be.configure(backend_url)
	if not await be.ensure_account("远程玩家B", "peer-secret-1"):
		print("[mp] 对端账号建立失败：", be.last_error)
		return null
	var peer := MPHarness.attach_silent(host, be.token, url, port)
	peer.connect_to_server()
	if not await _until(tree, func() -> bool: return not peer.player_id.is_empty(), 10000):
		print("[mp] 对端未能在 10 秒内完成握手")
		return null
	return peer


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
