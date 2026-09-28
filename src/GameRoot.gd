extends Node3D
## Composition root. Wires the systems together; owns no gameplay logic itself.

var rig: TimeWeatherRig
var water: WaterBodies
var major_roads: MajorRoads
var population: PopulationSystem
var crowd: CrowdSystem
var traffic: TrafficSystem
var weather: WeatherSystem
var silhouette: FarSilhouette
var streamer: WorldStreamer
var player: Player
var car: Car
var hud: DebugHUD
var creation: CreationSystem

const SPAWN := Vector3(1150.0, 0.6, 300.0)
const SPAWN_YAW := -PI * 0.5

var _report: Array[String] = []
var _shot_dir: String = ""
var _shot_every: float = 6.0
var _shot_left: int = 0
var _shot_t: float = 0.0
var _shot_n: int = 0


func _read_cli() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot-dir="):
			_shot_dir = a.trim_prefix("--shot-dir=")
			_shot_left = 4
		elif a.begins_with("--shots="):
			_shot_left = int(a.trim_prefix("--shots="))
		elif a.begins_with("--shot-every="):
			_shot_every = float(a.trim_prefix("--shot-every="))
		elif a.begins_with("--time="):
			GameGlobals.set_time(float(a.trim_prefix("--time=")))
		elif a.begins_with("--weather="):
			GameGlobals.set_weather(int(a.trim_prefix("--weather=")), 0.9)
		elif a.begins_with("--spawn="):
			var parts := a.trim_prefix("--spawn=").split(",")
			if parts.size() == 2:
				var sp := _find_spawn(Vector2(float(parts[0]), float(parts[1])))
				player.position = Vector3(sp.x, 1.2, sp.y)
		elif a == "--census":
			_census()
		elif a == "--create-test":
			_create_test()
		elif a.begins_with("--demo-build="):
			# Places a row of player-built objects in front of the camera and enters the
			# editor, so one screenshot covers the generators, the toolbar and the ghost.
			var n := int(a.trim_prefix("--demo-build="))
			for i in n:
				creation.tpl_i = i % BuildTemplates.count()
				creation.yaw = float(i) * 0.35
				creation.place(Vector2(900.0 + float(i) * 95.0, 520.0))
			creation.set_active(true)
			player.fly = true
		elif a.begins_with("--view="):
			# --view=pitch,yaw,lift  — an aimable rig so the street pattern can be inspected
			# from above without needing a fly-through.
			var v := a.trim_prefix("--view=").split(",")
			if v.size() == 3:
				player.pitch = float(v[0])
				player.yaw = float(v[1])
				player.cam_pivot.rotation.y = float(v[1])
				player.spring.rotation.x = float(v[0])
				player.position.y = float(v[2])
				player.fly = true
		elif a.begins_with("--quality="):
			QualityPresets.set_tier(int(a.trim_prefix("--quality=")))


func _ms(pf: Dictionary, key: String, n: float) -> float:
	return float(pf.get(key, 0)) / n / 1000.0


func _capture() -> void:
	# One extra frame so the shader/attachment state is current.
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	var name := "%s/shot_%02d_t%04.1f.png" % [_shot_dir, _shot_n, GameGlobals.time_of_day]
	var err := img.save_png(name)
	var st := streamer.stats()
	print(("[shot] %s err=%d %dx%d chunks=%d/%d tris=%s built=%d freed=%d requeue=%d jumps=%d " +
		"build_us=%d fps=%.1f silhouettes=%d") % [
		name, err, img.get_width(), img.get_height(), st["alive"], st["wanted"], st["tris"],
		st["built_total"], st["freed"], st["requeues"], st["jumps"], st["build_us"],
		Engine.get_frames_per_second(), silhouette.tile_count()])
	var pf := ChunkBuilder.profile_totals()
	var n := maxf(float(pf.get("n", 1)), 1.0)
	print("[prof] chunks=%d  blocks=%.1fms  streets=%.1fms  ground=%.1fms  furniture=%.1fms" % [
		int(n), _ms(pf, "blocks", n), _ms(pf, "streets", n), _ms(pf, "ground", n),
		_ms(pf, "furniture", n)])
	print("[prof.ground] water=%.1fms height=%.1fms colour=%.1fms emit=%.1fms" % [
		_ms(pf, "g_water", n), _ms(pf, "g_height", n), _ms(pf, "g_colour", n),
		_ms(pf, "g_emit", n)])
	var ms := CityData.memo_stats()
	print("[prof.memo] hits=%d miss=%d grid=%d" % [int(ms["hits"]), int(ms["miss"]),
		int(ms["cells"])])
	print(("[prof.ground] natural=%d/%d fields=%.1fms") % [
		int(pf.get("g_natural", 0)), int(n) * 100, _ms(pf, "sc_fields", n)])
	_shot_n += 1


func _ready() -> void:
	print("=== SHANGHAI: OPEN WORLD boot ===")
	randomize()

	rig = TimeWeatherRig.new()
	rig.name = "TimeWeatherRig"
	add_child(rig)

	streamer = WorldStreamer.new()
	streamer.name = "WorldStreamer"
	add_child(streamer)

	# Shanghai sits on an alluvial plain, so one infinite plane is a legitimate ground
	# collider rather than a shortcut — the streamed meshes only add relief at the river.
	var ground := StaticBody3D.new()
	ground.name = "GroundPlane"
	ground.collision_layer = 1
	ground.collision_mask = 0
	var gcs := CollisionShape3D.new()
	gcs.shape = WorldBoundaryShape3D.new()
	ground.add_child(gcs)
	add_child(ground)

	water = WaterBodies.new()
	water.name = "WaterBodies"
	add_child(water)

	major_roads = MajorRoads.new()
	major_roads.name = "MajorRoads"
	add_child(major_roads)

	var landmarks := Landmarks.new()
	landmarks.name = "Landmarks"
	add_child(landmarks)

	population = PopulationSystem.new()
	population.name = "PopulationSystem"
	add_child(population)

	crowd = CrowdSystem.new()
	crowd.name = "CrowdSystem"
	add_child(crowd)

	traffic = TrafficSystem.new()
	traffic.name = "TrafficSystem"
	add_child(traffic)

	weather = WeatherSystem.new()
	weather.name = "WeatherSystem"
	add_child(weather)

	silhouette = FarSilhouette.new()
	silhouette.name = "FarSilhouette"
	add_child(silhouette)

	player = Player.new()
	player.name = "Player"
	var spawn := _find_spawn(Vector2(SPAWN.x, SPAWN.z))
	player.position = Vector3(spawn.x, 1.2, spawn.y)
	add_child(player)
	player.yaw = SPAWN_YAW
	player.cam_pivot.rotation.y = SPAWN_YAW

	car = Car.new()
	car.name = "Car_01"
	car.collision_layer = 2
	car.collision_mask = 1
	car.position = Vector3(spawn.x, 1.2, spawn.y) + Vector3(0.0, 0.0, 9.0)
	car.rotation.y = SPAWN_YAW
	add_child(car)

	hud = DebugHUD.new()
	hud.name = "DebugHUD"
	add_child(hud)

	creation = CreationSystem.new()
	creation.name = "CreationSystem"
	add_child(creation)

	GameGlobals.advance_time(0.0)
	QualityPresets.set_tier(QualityPresets.Tier.HIGH)
	streamer.set_origin(spawn)
	silhouette.set_focus(player.global_position)
	_report.append("world_half=%f chunk=%f" % [GameGlobals.WORLD_HALF, GameGlobals.CHUNK_SIZE])
	_report.append("roads=%d landmarks=%d" % [CityData.roads.size(), CityData.LANDMARKS.size()])
	_report.append("spawn=%s" % str(spawn))
	print("=== boot ok: %s ===" % " | ".join(_report))
	_read_cli()


## End-to-end exercise of the creation stack: place, edit, undo, redo, delete, save, reload.
## Run headless with --create-test; every line is an observed value, not an expectation.
var _fails := 0


func _check(what: String, got: Variant, want: Variant) -> void:
	var ok := str(got) == str(want)
	if not ok:
		_fails += 1
	print("[test] %s %-34s got=%s want=%s" % ["PASS" if ok else "FAIL", what,
		str(got), str(want)])


func _create_test() -> void:
	print("=== creation self-test ===")
	creation.clear_all()
	if FileAccess.file_exists(CreationSystem.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CreationSystem.SAVE_PATH))
	_check("start empty", creation.objects.size(), 0)

	creation.tpl_i = 0
	var ids: Array = []
	for i in 5:
		ids.append(creation.place(Vector2(200.0 * float(i), 640.0)))
	_check("placed 5 objects", creation.objects.size(), 5)
	_check("5 scene nodes", creation.nodes.size(), 5)
	_check("undo depth", creation._undo.size(), 5)

	var tower: Node3D = creation.nodes[ids[0]]
	var tris := 0
	for mi in tower.get_children():
		if mi is MeshInstance3D:
			tris += (mi as MeshInstance3D).mesh.get_surface_count()
	_check("tower realized with meshes", tris > 0, true)
	_check("tower has bounds", (creation.bounds[ids[0]] as AABB).has_volume(), true)
	_check("tower has collision", (tower.get_child(
		tower.get_child_count() - 1) as StaticBody3D).get_child_count() > 0, true)

	creation.select(ids[2])
	var yaw0: float = creation.objects[ids[2]]["yaw"]
	creation.rotate_selected(PI / 4.0)
	_check("rotate applied", is_equal_approx(
		float(creation.objects[ids[2]]["yaw"]), yaw0 + PI / 4.0), true)
	creation.undo()
	_check("undo restores yaw", is_equal_approx(
		float(creation.objects[ids[2]]["yaw"]), yaw0), true)
	creation.redo()
	_check("redo re-applies yaw", is_equal_approx(
		float(creation.objects[ids[2]]["yaw"]), yaw0 + PI / 4.0), true)

	creation.scale_selected(2.0)
	_check("scale applied", is_equal_approx(
		float(creation.objects[ids[2]]["scale"]), 2.0), true)
	creation.undo()
	_check("undo restores scale", is_equal_approx(
		float(creation.objects[ids[2]]["scale"]), 1.0), true)

	creation.select(ids[4])
	creation.duplicate_selected()
	_check("duplicate adds one", creation.objects.size(), 6)
	creation.remove(ids[4])
	_check("delete removes one", creation.objects.size(), 5)
	creation.undo()
	_check("undo brings it back", creation.objects.size(), 6)

	var before: Array = []
	for k in creation.objects.keys():
		before.append((creation.objects[k] as Dictionary).duplicate())
	_check("save returns true", creation.save_edits(), true)
	_check("save file exists", FileAccess.file_exists(CreationSystem.SAVE_PATH), true)
	creation.clear_all()
	_check("cleared", creation.objects.size(), 0)
	_check("load returns count", creation.load_edits(), 6)
	var same := true
	for st in before:
		var got: Dictionary = creation.objects[int(st["id"])]
		for f in ["tpl", "x", "z", "yaw", "scale"]:
			if str(got[f]) != str(st[f]):
				same = false
	_check("reload is lossless", same, true)
	_check("reload re-renders", creation.nodes.size(), 6)
	_check("seed is stable per id",
		is_equal_approx(creation._seed_of(3), creation._seed_of(3)), true)

	creation.clear_all()
	if FileAccess.file_exists(CreationSystem.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CreationSystem.SAVE_PATH))
	print("=== creation self-test: %s (%d failures) ===" % ["PASS" if _fails == 0 else "FAIL",
		_fails])


## Sampling pass over the whole lattice: how many blocks exist, how many get paving, and how
## dense the street graph actually is. Reported once at boot behind --census.
func _census() -> void:
	var cells := 0
	var plates := 0
	var edges := 0
	var kinds: Dictionary = {}
	var span := int(GameGlobals.WORLD_HALF / Lattice.BASE_U) + 1
	for i in range(-span, span + 1):
		for j in range(-span, span + 1):
			var c := Lattice.cell_center(i, j)
			if absf(c.x) > 5000.0 or absf(c.y) > 5000.0:
				continue
			cells += 1
			var k := Lattice.cell_kind(i, j)
			kinds[k] = int(kinds.get(k, 0)) + 1
			if not CityData.blocks_building(c, -6.0) and CityData.major_gap(c) > -2.0:
				plates += 1
			for axis in 2:
				if Lattice.edge_present(i, j, axis):
					edges += 1
	print("[census] cells=%d plates=%d edges=%d edges_per_cell=%.2f" % [cells, plates, edges,
		float(edges) / float(maxi(cells, 1))])
	print("[census] kinds=%s" % str(kinds))


## Walk outward until we land on an at-grade carriageway. A road centreline is the only
## place guaranteed free of buildings, water and park ground, and preferring a surface
## street keeps the avatar out from under a viaduct deck on the first frame.
func _find_spawn(ideal: Vector2) -> Vector2:
	var radii := [0.0, 10.0, 22.0, 38.0, 58.0, 82.0, 110.0, 145.0, 190.0, 250.0, 320.0, 420.0]
	var fallback := Vector2.INF
	for rv in radii:
		var r: float = rv
		for k in 24:
			var th := TAU * float(k) / 24.0
			var p := ideal + Vector2(cos(th), sin(th)) * r
			if CityData.water_dist_exact(p) < 2.0 or CityData.major_gap(p) > -1.0:
				continue
			if not CityData.major_elevated_at(p):
				return p
			if fallback == Vector2.INF:
				fallback = p
	if fallback != Vector2.INF:
		return fallback
	print("[spawn] no carriageway found near %s" % str(ideal))
	return ideal


func _process(delta: float) -> void:
	if _shot_left > 0:
		_shot_t += delta
		if _shot_t >= _shot_every:
			_shot_t = 0.0
			_shot_left -= 1
			_capture()
			if _shot_left == 0:
				get_tree().create_timer(2.0).timeout.connect(func():
					print("[shot] done")
					get_tree().quit())
	var focus := player.camera_position()
	var want := Vector2(focus.x, focus.z)
	# Re-seed the stream only on a chunk boundary. A distance threshold makes the wanted set
	# churn every few frames while the camera swings, and each churn rebuilds geometry.
	if CityData.chunk_of(want) != CityData.chunk_of(streamer.origin_of_interest):
		streamer.set_origin(want)
	silhouette.set_focus(focus)
	var cam := player.camera_position()
	crowd.focus = cam
	traffic.focus = cam
	traffic.night = rig.night_factor()
	traffic.wet = rig.wet_factor()
	var hour := GameGlobals.time_of_day
	crowd.set_clock(hour, rig.wet_factor())
	traffic.set_time_factor(hour)
	weather.follow(cam)
	hud.feed(delta, _snap())


func _snap() -> Dictionary:
	return {
		"pos": player.global_position if player != null else Vector3.ZERO,
		"streamer": streamer.stats(),
		"silhouette": silhouette.tile_count(),
		"night": rig.night_factor(),
		"car_speed": car.speed_kmh() if car != null else 0.0,
		"drive": GameGlobals.game_mode == GameGlobals.GameMode.DRIVE,
		"npc": crowd.stats(),
		"cars": traffic.stats(),
		"creation": creation.stats(),
	}


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F:
				_toggle_vehicle()
			KEY_V:
				var nxt: int = (GameGlobals.weather_kind + 1) % 7
				GameGlobals.set_weather(nxt, 0.85)
				GameGlobals.say("天气：%s" % GameGlobals.Weather.keys()[nxt])
			KEY_T:
				GameGlobals.advance_time(2.0)
				GameGlobals.say("时间 %02d:%02d" % [int(GameGlobals.time_of_day),
					int(fmod(GameGlobals.time_of_day, 1.0) * 60.0)])
			KEY_P:
				QualityPresets.cycle()
			KEY_F1:
				GameGlobals.say("控制：WASD 移动 / Shift 疾跑 / 空格 跳跃 / C 视角 / F 上下车 / " +
					"V 天气 / T 时间 / P 画质 / B 建造模式 / M 地图 / Y 复位")
			KEY_B:
				creation.toggle()
				player.fly = creation.active


func _toggle_vehicle() -> void:
	if GameGlobals.game_mode == GameGlobals.GameMode.DRIVE:
		GameGlobals.game_mode = GameGlobals.GameMode.PLAY
		car.driving = false
		car.freeze = true
		player.show_body()
		player.camera.current = true
		player.position = car.global_position + Vector3(2.6, 0.4, 0)
		GameGlobals.say("下车")
	else:
		if player.global_position.distance_to(car.global_position) < 7.5:
			GameGlobals.game_mode = GameGlobals.GameMode.DRIVE
			car.driving = true
			car.freeze = false
			car.set_headlights(rig.night_factor() > 0.5)
			player.hide_body()
			car.cam.current = true
			GameGlobals.say("上车 — WASD 驾驶，空格手刹")
