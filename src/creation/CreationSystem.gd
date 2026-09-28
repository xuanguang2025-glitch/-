class_name CreationSystem
extends Node3D
## The player's city editor: place, move, rotate, scale, duplicate, delete, undo, save.
##
## Placed objects are built with the same generators as the procedural city and stored as
## plain data, so a save file is a list of transforms rather than a pile of serialised nodes,
## and reloading reproduces the identical building because its window pattern is keyed off
## the object's own id instead of a rolling random.

signal changed

const GRID := 2.0
const ROT_STEP := PI / 12.0
const SCALE_STEP := 1.1
const NUDGE := 4.0
const SAVE_PATH := "user://city_edits.json"
## Placed objects sit on the world layer so the avatar collides with them, plus a private
## bit so the editor can pick them without hitting terrain.
const LAYER_WORLD := 1
const LAYER_EDIT := 4

enum Tool { BUILDING, ROAD, TERRAIN, DECOR, VEHICLE, NPC, QUEST }

var active := false
var tool: int = Tool.BUILDING
var tpl_i := 0
var yaw := 0.0
var obj_scale := 1.0

var objects: Dictionary = {}		# id -> {id, tpl, x, z, yaw, scale}
var nodes: Dictionary = {}			# id -> Node3D
var bounds: Dictionary = {}			# id -> AABB, local to the object node
var selected := -1
var next_id := 1

var _undo: Array = []
var _redo: Array = []
var _ghost: Node3D
var _ghost_key := ""
var _mark: MeshInstance3D
var _mark_mat: StandardMaterial3D
var camera: Camera3D

var _todo_tools := {
	Tool.ROAD: "道路工具", Tool.TERRAIN: "地形工具", Tool.DECOR: "装饰工具",
	Tool.VEHICLE: "车辆工具", Tool.NPC: "NPC 工具", Tool.QUEST: "任务工具",
}


func _ready() -> void:
	add_to_group("creation")
	_ghost = Node3D.new()
	_ghost.visible = false
	add_child(_ghost)
	_mark_mat = StandardMaterial3D.new()
	_mark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mark_mat.albedo_color = Color(1.0, 0.82, 0.25, 0.22)
	_mark_mat.emission_enabled = true
	_mark_mat.emission = Color(1.0, 0.78, 0.2)
	_mark_mat.emission_energy_multiplier = 1.4
	_mark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	load_edits()


func toggle() -> void:
	set_active(not active)


func set_active(on: bool) -> void:
	active = on
	if on:
		GameGlobals.set_mode(GameGlobals.GameMode.BUILD)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		GameGlobals.say("创造模式 — 左键放置/选中 · Ctrl+左键删除 · 方向键移动 · R 旋转 · " +
			"[ ] 缩放 · Ctrl+D 复制 · Del 删除 · Ctrl+Z/Y 撤销重做 · Tab 换模板 · E 存盘 · Q 退出")
	else:
		GameGlobals.set_mode(GameGlobals.GameMode.PLAY)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_ghost.visible = false


# --- Templates --------------------------------------------------------------
func _tpl() -> Dictionary:
	return BuildTemplates.get_tpl(tpl_i)


## Scale applies to the footprint and to the height, which for the floor-count generators
## means the building gains and loses storeys rather than growing floor-to-floor thickness.
func _tpl_scaled(sc: float) -> Dictionary:
	var t: Dictionary = _tpl().duplicate()
	t["size"] = Vector2(t["size"]) * sc
	t["height"] = float(t["height"]) * sc
	return t


func _tpl_of(id: String, sc: float) -> Dictionary:
	var t: Dictionary = BuildTemplates.find(id).duplicate()
	t["size"] = Vector2(t["size"]) * sc
	t["height"] = float(t["height"]) * sc
	return t


# --- Ghost preview ----------------------------------------------------------
## Rebuild the preview only when something visible about it changed; generating a tower is
## not cheap enough to redo on every mouse move.
func _update_ghost(c: Vector2) -> void:
	var key := "%s|%d|%d" % [String(_tpl()["id"]), int(round(yaw * 100)),
		int(round(obj_scale * 100))]
	if key != _ghost_key:
		_ghost_key = key
		_rebuild_ghost()
	_ghost.position = Vector3(c.x, CityData.terrain_y(c), c.y)
	_ghost.rotation.y = -yaw


func _rebuild_ghost() -> void:
	for k in _ghost.get_children():
		(k as Node).free()
	var ctx := ChunkCtx.new()
	ctx.setup(7)
	ctx.detail = true
	var t := _tpl_scaled(obj_scale)
	BuildTemplates.build(ctx, t, BuildTemplates.rect(Vector2.ZERO, Vector2(t["size"]), 0.0), 0.5)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.25, 0.85, 1.0, 0.32)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	for f in [ctx.buildings, ctx.props, ctx.emissive]:
		if f.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = f.commit()
		mi.material_overlay = m
		_ghost.add_child(mi)


# --- Placement --------------------------------------------------------------
func _ground_point() -> Vector2:
	if camera == null:
		return Vector2.ZERO
	var mp := get_viewport().get_mouse_position()
	var o := camera.project_ray_origin(mp)
	var d := camera.project_ray_normal(mp)
	if absf(d.y) < 0.0001:
		return Vector2(o.x, o.z)
	# Hit the flat plane first, then re-read the terrain height there: near the river the
	# ground is not at zero and a single pass would float the preview.
	var p := o + d * (-o.y / d.y)
	var y := CityData.terrain_y(Vector2(p.x, p.z))
	var t2 := (y - o.y) / d.y
	if t2 < 0.0:
		return _snap(Vector2(p.x, p.z))
	p = o + d * t2
	return _snap(Vector2(p.x, p.z))


func _snap(p: Vector2) -> Vector2:
	return Vector2(round(p.x / GRID) * GRID, round(p.y / GRID) * GRID)


func place(c: Vector2) -> int:
	var t := _tpl()
	var id := next_id
	next_id += 1
	var st := {"id": id, "tpl": String(t["id"]), "x": c.x, "z": c.y,
		"yaw": yaw, "scale": obj_scale}
	objects[id] = st
	_realize(st)
	_undo.append({"op": "add", "obj": st.duplicate()})
	_redo.clear()
	changed.emit()
	return id


## Objects are generated around their own origin and positioned by their node, so the whole
## thing is one transform on edit instead of a mesh rebuild per vertex.
func _realize(st: Dictionary) -> void:
	var id := int(st["id"])
	var old: Node = nodes.get(id)
	if old != null:
		old.free()
	var node := Node3D.new()
	node.name = "Built%d" % id
	add_child(node)
	var c := Vector2(float(st["x"]), float(st["z"]))
	var gy := CityData.terrain_y(c)
	node.position = Vector3(c.x, gy, c.y)
	node.rotation.y = -float(st["yaw"])
	var sc := float(st["scale"])
	var t: Dictionary = _tpl_of(String(st["tpl"]), sc)
	var ctx := ChunkCtx.new()
	ctx.setup(11)
	ctx.detail = true
	BuildTemplates.build(ctx, t, BuildTemplates.rect(Vector2.ZERO, Vector2(t["size"]), 0.0),
		_seed_of(id))
	var bags := [[ctx.buildings, Assets.facade_mat()], [ctx.props, Assets.props_mat()],
		[ctx.emissive, Assets.emissive_mat()]]
	for pair in bags:
		var f: MeshFusion = pair[0]
		if f.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = f.commit()
		mi.material_overlay = pair[1]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		node.add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD | LAYER_EDIT
	body.collision_mask = 0
	node.add_child(body)
	for cld in ctx.colliders:
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = Vector3(maxf(cld["s"].x, 0.6), maxf(cld["s"].y, 0.6), maxf(cld["s"].z, 0.6))
		cs.shape = sh
		cs.position = cld["c"] - Vector3(0.0, gy, 0.0)
		cs.rotation.y = cld["r"]
		body.add_child(cs)
	nodes[id] = node
	bounds[id] = _union(ctx)


func _union(ctx: ChunkCtx) -> AABB:
	var a := AABB()
	var seen := false
	for f in [ctx.buildings, ctx.props, ctx.emissive]:
		if f.is_empty():
			continue
		var b: AABB = f.aabb_of()
		a = b if not seen else a.merge(b)
		seen = true
	return a


## Window patterns and tints derive from this, so a saved building looks the same forever.
func _seed_of(id: int) -> float:
	return GameGlobals.hash2(id, 1741, 61)


# --- Selection and editing --------------------------------------------------
func pick() -> int:
	if camera == null:
		return -1
	var mp := get_viewport().get_mouse_position()
	var o := camera.project_ray_origin(mp)
	var q := PhysicsRayQueryParameters3D.create(o,
		o + camera.project_ray_normal(mp) * 1200.0, LAYER_EDIT)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return -1
	var n: Node = hit["collider"]
	while n != null and not String(n.name).begins_with("Built"):
		n = n.get_parent()
	return int(String(n.name).trim_prefix("Built")) if n != null else -1


func select(id: int) -> void:
	if _mark != null:
		_mark.free()
		_mark = null
	selected = id
	if not objects.has(id):
		return
	var st: Dictionary = objects[id]
	yaw = float(st["yaw"])
	obj_scale = float(st["scale"])
	tpl_i = _index_of(String(st["tpl"]))
	var box: AABB = bounds.get(id, AABB())
	if box.size == Vector3.ZERO:
		return
	_mark = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size + Vector3(1.6, 1.6, 1.6)
	_mark.mesh = bm
	_mark.material_overlay = _mark_mat
	_mark.position = box.get_center()
	(nodes[id] as Node3D).add_child(_mark)


func _index_of(tpl_id: String) -> int:
	for i in BuildTemplates.TEMPLATES.size():
		if String(BuildTemplates.TEMPLATES[i]["id"]) == tpl_id:
			return i
	return 0


func remove(id: int) -> void:
	if not objects.has(id):
		return
	var before := _snapshot(id)
	_destroy(id)
	_undo.append({"op": "del", "obj": before})
	_redo.clear()
	if selected == id:
		selected = -1
		_mark = null
	changed.emit()


func _destroy(id: int) -> void:
	var n: Node = nodes.get(id)
	if n != null:
		n.free()
	nodes.erase(id)
	objects.erase(id)
	bounds.erase(id)
	if selected == id:
		_mark = null
		selected = -1


func duplicate_selected() -> void:
	if selected < 0 or not objects.has(selected):
		return
	var st: Dictionary = _snapshot(selected)
	st["id"] = next_id
	next_id += 1
	var t := _tpl_of(String(st["tpl"]), float(st["scale"]))
	st["x"] = float(st["x"]) + Vector2(t["size"]).x * 0.75
	objects[int(st["id"])] = st
	_realize(st)
	_undo.append({"op": "add", "obj": st.duplicate()})
	_redo.clear()
	select(int(st["id"]))
	changed.emit()


func nudge_selected(dx: float, dz: float) -> void:
	_edit_selected(func(s): s["x"] = float(s["x"]) + dx; s["z"] = float(s["z"]) + dz)


func rotate_selected(d: float) -> void:
	_edit_selected(func(s): s["yaw"] = float(s["yaw"]) + d)


func scale_selected(f: float) -> void:
	_edit_selected(func(s): s["scale"] = maxf(0.25, minf(6.0, float(s["scale"]) * f)))


## One undo entry per edit, with the whole record on both sides so redo needs no inverse
## logic and a failed redo can never half-apply.
func _edit_selected(fn: Callable) -> void:
	if selected < 0 or not objects.has(selected):
		return
	var before := _snapshot(selected)
	var after := before.duplicate()
	fn.call(after)
	objects[selected] = after
	_realize(after)
	_undo.append({"op": "mod", "before": before, "after": after.duplicate()})
	_redo.clear()
	select(selected)
	changed.emit()


func _snapshot(id: int) -> Dictionary:
	return (objects[id] as Dictionary).duplicate()


func undo() -> void:
	if _undo.is_empty():
		GameGlobals.say("没有可撤销的操作")
		return
	var op: Dictionary = _undo.pop_back()
	_redo.append(op)
	_apply(op, false)
	changed.emit()


func redo() -> void:
	if _redo.is_empty():
		GameGlobals.say("没有可重做的操作")
		return
	var op: Dictionary = _redo.pop_back()
	_undo.append(op)
	_apply(op, true)
	changed.emit()


func _apply(op: Dictionary, forward: bool) -> void:
	match String(op["op"]):
		"add":
			if forward:
				_put(op["obj"])
			else:
				_destroy(int((op["obj"] as Dictionary)["id"]))
		"del":
			if forward:
				_destroy(int((op["obj"] as Dictionary)["id"]))
			else:
				_put(op["obj"])
		"mod":
			_put(op["after"] if forward else op["before"])


func _put(st: Dictionary) -> void:
	var id := int(st["id"])
	objects[id] = (st as Dictionary).duplicate()
	_realize(objects[id])
	if selected == id:
		select(id)


# --- Persistence ------------------------------------------------------------
func save_edits() -> bool:
	var arr: Array = []
	for k in objects.keys():
		arr.append(objects[k])
	arr.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		GameGlobals.say("存盘失败，错误码 %d" % FileAccess.get_open_error())
		return false
	f.store_string(JSON.stringify({"version": 1, "next_id": next_id, "objects": arr}))
	f.close()
	GameGlobals.say("已保存 %d 件作品" % arr.size())
	return true


func load_edits() -> int:
	if not FileAccess.file_exists(SAVE_PATH):
		return 0
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return 0
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return 0
	next_id = maxi(next_id, int(parsed.get("next_id", 1)))
	var n := 0
	for st in parsed.get("objects", []):
		var id := int(st["id"])
		objects[id] = st
		_realize(st)
		next_id = maxi(next_id, id + 1)
		n += 1
	if n > 0:
		print("[creation] loaded %d saved objects" % n)
	return n


func clear_all() -> void:
	for id in nodes.keys():
		(nodes[id] as Node).free()
	nodes.clear()
	objects.clear()
	bounds.clear()
	selected = -1
	_mark = null
	_undo.clear()
	_redo.clear()
	changed.emit()


func stats() -> Dictionary:
	return {"objects": objects.size(), "selected": selected, "tool": tool,
		"tpl": String(_tpl()["name"]), "undo": _undo.size(), "redo": _redo.size(),
		"active": active}


# --- Input ------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey and event.pressed:
		var c: bool = event.ctrl_pressed or event.meta_pressed
		match event.keycode:
			KEY_Q:
				set_active(false)
			KEY_E:
				save_edits()
			KEY_R:
				if c:
					duplicate_selected()
				else:
					rotate_selected(ROT_STEP)
			KEY_DELETE, KEY_BACKSPACE:
				if selected >= 0:
					remove(selected)
			KEY_Z:
				if c:
					undo()
			KEY_Y:
				if c:
					redo()
			KEY_BRACKETLEFT:
				scale_selected(1.0 / SCALE_STEP)
			KEY_BRACKETRIGHT:
				scale_selected(SCALE_STEP)
			KEY_TAB:
				tpl_i = (tpl_i + 1) % BuildTemplates.count()
				_ghost_key = ""
				GameGlobals.say("模板：%s" % String(_tpl()["name"]))
			KEY_UP:
				nudge_selected(0.0, -NUDGE if not c else -NUDGE * 5.0)
			KEY_DOWN:
				nudge_selected(0.0, NUDGE if not c else NUDGE * 5.0)
			KEY_LEFT:
				nudge_selected(-NUDGE if not c else -NUDGE * 5.0, 0.0)
			KEY_RIGHT:
				nudge_selected(NUDGE if not c else NUDGE * 5.0, 0.0)
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7:
				_set_tool(int(event.keycode) - int(KEY_1))
			_:
				return
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var hit_id := pick()
			if event.ctrl_pressed and hit_id >= 0:
				remove(hit_id)
			elif hit_id >= 0:
				select(hit_id)
			else:
				select(place(_ground_point()))
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			select(-1)
			get_viewport().set_input_as_handled()


func _set_tool(t: int) -> void:
	tool = t
	if _todo_tools.has(t):
		GameGlobals.say("%s — 待实现（当前仅建筑工具可用）" % String(_todo_tools[t]))
	else:
		GameGlobals.say("工具：建筑 — Tab 换模板，共 %d 种" % BuildTemplates.count())


func _process(_delta: float) -> void:
	if not active or tool != Tool.BUILDING:
		return
	if camera == null or not is_instance_valid(camera):
		camera = get_viewport().get_camera_3d() as Camera3D
		if camera == null:
			return
	if selected >= 0:
		_ghost.visible = false
		return
	_ghost.visible = true
	_update_ghost(_ground_point())
