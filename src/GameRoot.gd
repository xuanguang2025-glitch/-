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
var _want_validate := false
var _want_stress := 0
var _want_load := false
var _want_sync := false
var _want_sim := false
var _want_soak := 0
var sim: CitySim
var _sim_hour := -1
var _boot_us := 0
var _load_reported := false
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
		elif a.begins_with("--backend="):
			await _setup_backend(a.trim_prefix("--backend="))
		elif a == "--backend-sync-test":
			_want_sync = true
		elif a == "--sim-test":
			_want_sim = true
		elif a.begins_with("--sim-soak="):
			_want_soak = int(a.trim_prefix("--sim-soak="))
		elif a == "--validate-test":
			# Needs streamed chunks to answer "is a generated building already here", so it
			# waits for the world instead of running at boot.
			_want_validate = true
		elif a.begins_with("--bench-stress="):
			_want_stress = int(a.trim_prefix("--bench-stress="))
		elif a == "--bench-load":
			_want_load = true
			_boot_us = Time.get_ticks_usec()
		elif a.begins_with("--demo-build="):
			# Places a row of player-built objects and enters the editor, so one screenshot
			# covers the generators, the toolbar and the ghost. The demo locates itself through
			# the same validator the editor uses: once the official core started refusing towers,
			# a hardcoded row coordinate would have quietly produced an empty screenshot.
			var n := int(a.trim_prefix("--demo-build="))
			var spots := ValidationTests.find_spots(n + 1, 30.0, streamer)
			for i in mini(n, spots.size()):
				creation.tpl_i = i % BuildTemplates.count()
				creation.yaw = float(i) * 0.35
				creation.place(spots[i])
			if not spots.is_empty():
				var b0: Vector2 = spots[0]
				creation._set_tool(CreationSystem.Tool.DECOR)
				for i in BuildTemplates.DECOR.size():
					creation.tpl_i = i
					creation.place(b0 + Vector2(float(i) * 9.0 - 36.0, -40.0))
				creation._set_tool(CreationSystem.Tool.BUILDING)
				player.position = Vector3(b0.x, 2.0, b0.y + 58.0)
			creation.tpl_i = 0
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

	# The simulation inherits the city the generator actually made: its clock, wetness and
	# hourly activity curve all come from the existing systems rather than its own copy.
	sim = CitySim.new()
	sim.name = "CitySim"
	add_child(sim)
	sim.configure(
		func() -> float: return GameGlobals.time_of_day,
		rig.wet_factor,
		func(h: float) -> float: return population.active_share(h))
	sim.bootstrap(population)
	print("[sim] %s" % str(sim.stats()))

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
	creation.streamer = streamer
	add_child(creation)

	GameGlobals.advance_time(0.0)
	QualityPresets.set_tier(QualityPresets.Tier.HIGH)
	streamer.set_origin(spawn)
	silhouette.set_focus(player.global_position)
	_report.append("world_half=%f chunk=%f" % [GameGlobals.WORLD_HALF, GameGlobals.CHUNK_SIZE])
	_report.append("roads=%d landmarks=%d" % [CityData.roads.size(), CityData.LANDMARKS.size()])
	_report.append("spawn=%s" % str(spawn))
	print("=== boot ok: %s ===" % " | ".join(_report))
	await _read_cli()

const DEVICE_PATH := "user://device.json"


## Establishes the client half of the backend link. The credential is a generated device
## secret kept in user://, so the same install keeps the same identity without the player
## ever typing a password; real auth is a documented swap point.
func _setup_backend(url: String) -> void:
	creation.backend = BackendClient.new()
	creation.backend.name = "BackendClient"
	add_child(creation.backend)
	creation.backend.configure(url)
	var dev: Dictionary = {}
	if FileAccess.file_exists(DEVICE_PATH):
		var rf := FileAccess.open(DEVICE_PATH, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(rf.get_as_text())
		rf.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			dev = parsed
	if dev.is_empty():
		dev = {"name": "玩家%04d" % randi_range(0, 9999),
			"secret": "%s%s" % [str(randi()), str(randi())]}
		var wf := FileAccess.open(DEVICE_PATH, FileAccess.WRITE)
		wf.store_string(JSON.stringify(dev))
		wf.close()
	var ok: bool = await creation.backend.ensure_account(
		String(dev["name"]), String(dev["secret"]))
	print("[backend] %s account=%s online=%s %s" % [url, dev["name"], ok,
		"" if ok else creation.backend.last_error])
	if ok:
		var n := await creation.pull_save()
		if n > 0:
			print("[backend] restored %d objects from server" % n)


## End-to-end client<->backend proof. Deferred until chunks are streamed because it places
## real objects through the validator.
func _sync_test() -> void:
	print("=== backend sync test ===")
	if creation.backend == null or not creation.backend.online:
		print("[sync] FAIL  未配置 --backend=<url>")
		_fails += 1
	else:
		if await creation.sync_roundtrip_test():
			print("[sync] PASS")
		else:
			_fails += 1
	print("=== backend sync test: %s (%d failures) ===" % ["PASS" if _fails == 0 else "FAIL", _fails])


## The simulation's own acceptance contract lives in SimTests; these are the CLI entry points,
## and the failures they return join the boot verdict.
func _sim_test() -> void:
	_fails += SimTests.run(sim, population, crowd, traffic)


func _sim_soak(hours: int) -> void:
	_fails += SimTests.soak(sim, hours)


## The placement validator's contract lives in ValidationTests; this is the CLI entry point.
func _validate_test() -> void:
	_fails += ValidationTests.run(creation, streamer, sim)


## Phase 37 test 3: build the maximum the editor can take and report what it cost. This is a
## measurement, not an assertion of a number we made up - the gate lives in run.sh so the
## threshold is visible in one place instead of buried in test code.
func _stress_test(n: int) -> void:
	print("=== build stress: %d objects ===" % n)
	creation.clear_all()
	var half := 12.0
	var placed := 0
	var t0 := Time.get_ticks_usec()
	var scanned := 0
	var i := 0
	while placed < n and i < 900:
		for j in 900:
			if placed >= n:
				break
			var p := Vector2(-5800.0 + float(i) * 14.0, -5800.0 + float(j) * 14.0)
			scanned += 1
			if Validation.check(p, half, [], streamer) != Validation.Reason.OK:
				continue
			creation.tpl_i = placed % BuildTemplates.count()
			creation.obj_scale = 0.5
			if creation.place(p) >= 0:
				placed += 1
		i += 1
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var mem := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	print(("[stress] placed=%d/%d scanned=%d time=%.0fms per_object=%.2fms static_mem=%.1fMB " +
		"nodes=%d") % [placed, n, scanned, ms, ms / maxf(float(placed), 1.0), mem,
			creation.nodes.size()])
	var t1 := Time.get_ticks_usec()
	creation.clear_all()
	print("[stress] teardown %d objects in %.0f ms" % [placed,
		float(Time.get_ticks_usec() - t1) / 1000.0])
	print("[stress] result=%s (placed>=90%% requested: %s)" % [
		"PASS" if placed >= int(n * 0.9) else "FAIL", str(placed >= int(n * 0.9))])


## End-to-end exercise of the creation stack: place, edit, undo, redo, delete, save, reload.
## Run headless with --create-test; every line is an observed value, not an expectation.
var _fails := 0


func _check(what: String, got: Variant, want: Variant) -> void:
	var ok := str(got) == str(want)
	if not ok:
		_fails += 1
	print("[test] %s %-34s got=%s want=%s" % ["PASS" if ok else "FAIL", what,
		str(got), str(want)])


## Asserts a condition and prints the observed values beside it. _check() compares two values;
## these assertions need "this must hold, and here is the evidence" — see review.sh rule R7.
func _check_that(what: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_fails += 1
	print("[test] %s %-40s %s" % ["PASS" if cond else "FAIL", what, detail])


func _create_test() -> void:
	print("=== creation self-test ===")
	creation.clear_all()
	if FileAccess.file_exists(CreationSystem.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CreationSystem.SAVE_PATH))
	_check("start empty", creation.objects.size(), 0)

	creation.tpl_i = 0
	var spots := ValidationTests.find_spots(5, 30.0, streamer)
	_check("found 5 buildable spots", spots.size(), 5)
	var ids: Array = []
	for sp in spots:
		ids.append(creation.place(sp))
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

	# Phase 127 street furniture. Props come from their own palette and are placed at their
	# true metric size, so these assertions check that the palette, the generated geometry,
	# the scale exemption, the selection-follows-template rule and undo/redo all agree on that
	# — rather than only that "something appeared in the dictionary".
	creation._set_tool(CreationSystem.Tool.DECOR)
	_check("装饰面板构件种类", BuildTemplates.palette(true).size(), 9)
	_check("装饰工具取装饰表为当前模板", String(creation._tpl()["id"]), "plane_tree")
	var dspots := ValidationTests.find_spots(4, 3.0, streamer)
	_check("found 4 decor spots", dspots.size(), 4)
	var dids: Array = []
	for i in dspots.size():
		creation.tpl_i = i
		dids.append(creation.place(dspots[i]))
	_check("decor placed", creation.objects.size(), dspots.size())
	var prop_node: Node3D = creation.nodes[dids[1]]
	var bags := 0
	for mi in prop_node.get_children():
		if mi is MeshInstance3D:
			bags += 1
	_check("构件生成了几何袋", bags > 0, true)
	_check("构件带碰撞体", (prop_node.get_child(
		prop_node.get_child_count() - 1) as StaticBody3D).get_child_count() > 0, true)
	_check("构件存的是装饰 id", String(creation.objects[dids[1]]["tpl"]), "bench")
	creation.select(dids[1])
	_check("选中构件后工具跟随切换", creation.tool, CreationSystem.Tool.DECOR)
	_check("构件不参与缩放", str(creation._tpl_of("bench", 3.0)["size"]),
		str(Vector2(1.8, 0.9)))
	creation.remove(dids[0])
	creation.undo()
	_check("decor undo 恢复", creation.objects.size(), dspots.size())
	creation.redo()
	_check("decor redo 再删", creation.objects.size(), dspots.size() - 1)
	creation._set_tool(CreationSystem.Tool.BUILDING)
	# The palette index carries over between palettes rather than resetting, so what must hold
	# is that the current template belongs to the building table - not which entry it is.
	var back := String(creation._tpl()["id"])
	var in_build := false
	for t in BuildTemplates.TEMPLATES:
		if String(t["id"]) == back:
			in_build = true
	_check("切回建筑后模板来自建筑表", in_build, true)
	_check("切换工具不越界到另一张表", String(creation._tpl()["kind"]) != "prop", true)
	var dsave := creation.objects.size()
	_check("decor save", creation.save_edits(), true)
	creation.clear_all()
	_check("decor reload", creation.load_edits(), dsave)
	var kept := true
	for k in creation.objects.keys():
		var t: Dictionary = BuildTemplates.find(
			String((creation.objects[k] as Dictionary)["tpl"]))
		if String(t["kind"]) != "prop":
			kept = false
	_check("重载后仍是装饰构件", kept, true)
	creation.clear_all()

	# Phase 136 / 168: the point of the whole creation stack is that building something changes
	# the city, so this asserts the ledger moves because a player placed a shop - and that undo
	# and clear_all move it back. A shop count in a dictionary that the economy never hears
	# about would pass every editor test above and still be a fake.
	var mall_i := 0
	var shop_i := 0
	for i in BuildTemplates.TEMPLATES.size():
		if String(BuildTemplates.TEMPLATES[i]["id"]) == "mall":
			mall_i = i
		if String(BuildTemplates.TEMPLATES[i]["id"]) == "shopfront":
			shop_i = i
	creation._set_tool(CreationSystem.Tool.BUILDING)
	# A commercial placement only reaches the ledger where a ledger exists: CitySim bootstraps
	# the named districts the census found, and the official core refuses anything mall-sized,
	# so the test anchors on a district that is both simulated and open to building.
	var anchor := Vector2(INF, INF)
	for d in CityData.DISTRICTS:
		var dn := String(d["name"])
		if not sim.districts.has(dn):
			continue
		var dc := Vector2(float(d["cx"]), float(d["cz"]))
		if CreationZones.max_half(dc) < 40.0:
			continue
		anchor = dc
		break
	_check("找到可建造的被模拟街区", anchor != Vector2(INF, INF), true)
	var bspots := ValidationTests.find_spots(2, 40.0, streamer, anchor, 140)
	_check("found 2 commercial spots", bspots.size(), 2)
	var jobs0 := sim.total_employment()
	var shops0 := sim.total_shops()
	var money0 := sim.money_total()
	creation.tpl_i = mall_i
	var mid := creation.place(bspots[0])
	_check("商场放置成功", mid >= 0, true)
	_check_that("放置商场后城市就业增加",
		sim.total_employment() > jobs0, "%d -> %d" % [jobs0, sim.total_employment()])
	_check_that("放置商场后商铺计数进入账本",
		sim.total_shops() > shops0, "%d -> %d" % [shops0, sim.total_shops()])
	var jobs1 := sim.total_employment()
	creation.undo()
	_check_that("撤销商场后就业回落", sim.total_employment() < jobs1,
		"%d -> %d" % [jobs1, sim.total_employment()])
	_check_that("撤销后回到放置前的就业", sim.total_employment() == jobs0,
		"%d vs %d" % [sim.total_employment(), jobs0])
	creation.tpl_i = shop_i
	creation.place(bspots[1])
	_check_that("沿街商业同样计入就业", sim.total_employment() > jobs0,
		"%d -> %d" % [jobs0, sim.total_employment()])
	creation.clear_all()
	_check_that("清空作品后账本回到初值", sim.total_employment() == jobs0,
		"%d vs %d" % [sim.total_employment(), jobs0])
	_check_that("建造与拆除不凭空产生货币", sim.money_total() == money0,
		"%d vs %d" % [sim.money_total(), money0])

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
	if _want_validate and streamer.stats()["alive"] > 250:
		_want_validate = false
		_validate_test()
		get_tree().quit()
	if _want_sync and streamer.stats()["alive"] > 250:
		_want_sync = false
		await _sync_test()
		get_tree().quit()
	if _want_sim and streamer.stats()["alive"] > 250:
		_want_sim = false
		_sim_test()
		get_tree().quit()
	if _want_soak > 0 and streamer.stats()["alive"] > 250:
		var h := _want_soak
		_want_soak = 0
		_sim_soak(h)
		get_tree().quit()
	if _want_stress > 0 and streamer.stats()["alive"] > 250:
		var n := _want_stress
		_want_stress = 0
		_stress_test(n)
		get_tree().quit()
	if _want_load and not _load_reported:
		var st: Dictionary = streamer.stats()
		if st["wanted"] > 0 and st["alive"] >= st["wanted"]:
			_load_reported = true
			var ms := float(Time.get_ticks_usec() - _boot_us) / 1000.0
			print("[bench] streamed %d/%d chunks in %.0f ms (gate: 30000 ms) -> %s" % [
				st["alive"], st["wanted"], ms, "PASS" if ms < 30000.0 else "FAIL"])
			get_tree().quit()
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
	# Phase 109: the economy runs on the clock's hour, never per frame. At 480 s a day that is
	# one tick every 20 s. Catch-up is capped because a stalled frame must not turn into a
	# hundred-tick spike; the simulation then trails the clock, which is bounded and honest.
	var hh := int(hour)
	if _sim_hour < 0:
		_sim_hour = hh			# first frame: anchor to the clock, do not fast-forward
	elif hh != _sim_hour:
		var steps := posmod(hh - _sim_hour, 24)
		_sim_hour = hh
		for i in mini(steps, 3):
			sim.advance_hour()
		# One line per clock hour is the evidence that the live path ticks and that the
		# consumers react: agents/cars are what those factors produced this frame.
		print(("[sim] day %d hour %02d wet=%.2f shops=%d jobs=%d crowd_f=%.2f car_f=%.2f " +
			"agents=%d vehicles=%d") % [
			sim.day, hh, rig.wet_factor(), sim.total_shops(), sim.total_employment(),
			sim.crowd_factor_at(Vector2(cam.x, cam.z)),
			sim.car_factor_at(Vector2(cam.x, cam.z)),
			int(crowd.stats()["agents"]), int(traffic.stats()["cars"])])
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
		"sim": sim.stats(),
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
