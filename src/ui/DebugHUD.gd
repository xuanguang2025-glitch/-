class_name DebugHUD
extends CanvasLayer
## Black / graphite / white with a single tech-blue accent, per the design brief.
## Also the verification readout: framerate, streaming budget and triangle load are what
## the performance phase is judged on, so they stay on in development builds.

var root: PanelContainer
var label: Label
var _fps: float = 60.0
var _acc: float = 0.0
var _frames: int = 0


func _ready() -> void:
	layer = 60
	root = PanelContainer.new()
	root.position = Vector2(18, 18)
	root.self_modulate = Color(1, 1, 1, 0.92)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.040, 0.050, 0.82)
	sb.set_corner_radius_all(3)
	sb.border_color = Color(0.16, 0.42, 0.85, 0.55)
	sb.set_border_width_all(1)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	root.add_theme_stylebox_override("panel", sb)
	add_child(root)
	label = Label.new()
	label.add_theme_color_override("font_color", Color(0.90, 0.93, 0.97))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("outline_size", 2)
	label.text = "初始化中……"
	root.add_child(label)


func feed(delta: float, s: Dictionary) -> void:
	_acc += delta
	_frames += 1
	if _acc > 0.25:
		_fps = float(_frames) / _acc
		_acc = 0.0
		_frames = 0
	if s.is_empty():
		return
	var pos: Vector3 = s["pos"]
	var st: Dictionary = s["streamer"]
	var hour: float = GameGlobals.time_of_day
	var hh := int(hour)
	var mm := int(fmod(hour, 1.0) * 60.0)
	var dist := CityData.district_at(Vector2(pos.x, pos.z))
	var night: float = s["night"]
	var lines: Array[String] = []
	lines.append("SHANGHAI : OPEN WORLD")
	lines.append("")
	lines.append("FPS %.1f   三角面 %s   chunk %d/%d" % [_fps, _k(st["tris"]),
		st["alive"], st["wanted"]])
	lines.append("生成预算 %.2f ms   已建 %d" % [float(st["build_us"]) / 1000.0, st["built_total"]])
	lines.append("远景体块 %d   画质 %s" % [s["silhouette"], QualityPresets.cfg()["label"]])
	lines.append("")
	lines.append("位置 %.0f, %.0f  %s" % [pos.x, pos.z, dist["name"]])
	lines.append("时刻 %02d:%02d   夜间因子 %.2f" % [hh, mm, night])
	lines.append("天气 %s %.0f%%   现金 %.0f" % [_weather(), GameGlobals.weather_intensity * 100.0,
		GameGlobals.cash])
	var npc: Dictionary = s.get("npc", {})
	var cars: Dictionary = s.get("cars", {})
	lines.append("行人 %d   车辆 %d   隐蔽 %d   高峰 %.0f%%" % [
		npc.get("agents", 0), cars.get("cars", 0), npc.get("hidden", 0),
		float(cars.get("rush", 0.0)) * 100.0])
	var who: Dictionary = npc.get("who", {})
	if not who.is_empty():
		var prof: NPCProfile = who["prof"]
		lines.append("  近人 %.0fm  %s %d岁 %s  %s  心情%s" % [
			float(npc.get("near", 0.0)), prof.display_name, prof.age,
			OccupationTable.label(prof.occ), prof.state_label(), prof.feeling()])
	var cr: Dictionary = s.get("creation", {})
	if bool(cr.get("active", false)):
		lines.append("")
		lines.append("创造模式 · 工具 %d 建筑   模板 %s" % [int(cr["tool"]) + 1, cr["tpl"]])
		lines.append("作品 %d   选中 #%d   撤销栈 %d/%d" % [cr["objects"], cr["selected"],
			cr["undo"], cr["redo"]])
		lines.append("1建筑 2道路 3地形 4装饰 5车辆 6NPC 7任务")
	if s["drive"]:
		lines.append("")
		lines.append("车速 %.0f km/h" % s["car_speed"])
	lines.append("")
	lines.append("F1 控制列表   F 上下车   B 建造   V 天气   T 时间   P 画质")
	label.text = "\n".join(lines)


func _weather() -> String:
	var names := {0: "晴", 1: "多云", 2: "阴", 3: "小雨", 4: "暴雨", 5: "雾", 6: "台风"}
	return names.get(GameGlobals.weather_kind, "?")


func _k(n: int) -> String:
	if n > 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n > 1000:
		return "%.0fk" % (n / 1000.0)
	return str(n)
