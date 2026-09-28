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
var _ghost_mat: StandardMaterial3D
var _ghost_key := ""
var _mark: MeshInstance3D
var _mark_mat: StandardMaterial3D
var camera: Camera3D
var streamer: WorldStreamer
var backend: BackendClient

## Result of the last validation pass, surfaced in the HUD so a refused placement is
## attributable rather than mysterious.
var _reason: int = Validation.Reason.OK
var _cursor := Vector2(INF, INF)
var _road_a: Variant = null
var sim: CitySim
var crowd: CrowdSystem
var _business := BusinessRegistry.new()

var _todo_tools := {
	Tool.TERRAIN: "地形工具",
	Tool.VEHICLE: "车辆工具", Tool.QUEST: "任务工具",
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
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.25, 0.85, 1.0, 0.32)
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.no_depth_test = true
	sim = get_tree().get_first_node_in_group("sim")
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
## The catalogue the current tool cycles through. Buildings and street props are separate
## palettes, so Tab on the decoration tool walks benches and planters rather than twelve towers.
func _pal() -> Array:
	if tool == Tool.NPC:
		return BuildTemplates.npc_palette()
	return BuildTemplates.palette(tool == Tool.DECOR)


func _tpl() -> Dictionary:
	return BuildTemplates.get_at(_pal(), tpl_i)


## Scale applies to the footprint and to the height, which for the floor-count generators
## means the building gains and loses storeys rather than growing floor-to-floor thickness.
## Street props are excluded: a bench is placed at its true metric size, and letting the scale
## control lie about what would appear would make the ghost disagree with the built object.
func _tpl_scaled(sc: float) -> Dictionary:
	var t: Dictionary = _tpl().duplicate()
	if _no_scale(t):
		return t
	t["size"] = Vector2(t["size"]) * sc
	t["height"] = float(t["height"]) * sc
	return t


## Street furniture and people are placed at their true metric size: a bench that stretches to
## three metres is not a thing a street needs, and neither is a person.
static func _no_scale(t: Dictionary) -> bool:
	var k := String(t["kind"])
	return k == "prop" or k == "npc"


func _tpl_of(id: String, sc: float) -> Dictionary:
	var t: Dictionary = BuildTemplates.find(id).duplicate()
	if _no_scale(t):
		return t
	t["size"] = Vector2(t["size"]) * sc
	t["height"] = float(t["height"]) * sc
	return t


# --- Ghost preview ----------------------------------------------------------
## Rebuild the preview only when something visible about it changed; generating a tower is
## not cheap enough to redo on every mouse move. Validation runs every frame instead, so the
## preview turns red the moment it crosses into the river or onto a boulevard.
func _update_ghost(c: Vector2) -> void:
	_cursor = c
	var key := "%s|%d|%d" % [String(_tpl()["id"]), int(round(yaw * 100)),
		int(round(obj_scale * 100))]
	if key != _ghost_key:
		_ghost_key = key
		_rebuild_ghost()
	_ghost.position = Vector3(c.x, CityData.terrain_y(c), c.y)
	_ghost.rotation.y = -yaw
	_reason = _validate(c)
	_ghost_mat.albedo_color = (Color(0.20, 0.95, 0.45, 0.34) if _reason == Validation.Reason.OK
		else Color(0.98, 0.22, 0.18, 0.34))


func _half_footprint() -> float:
	var s: Vector2 = Vector2(_tpl()["size"]) * obj_scale
	return maxf(s.x, s.y) * 0.5


func _validate(c: Vector2) -> int:
	return Validation.check(c, _half_footprint(), _near_centers(), streamer,
		_projected_tris())


## What the world's player content costs, tracked per object by TriangleBudget.
var _budget := TriangleBudget.new()


## The simulation this content has to report to, resolved by group rather than assigned.
func _sim() -> CitySim:
	if sim == null:
		sim = get_tree().get_first_node_in_group("sim")
	return sim


## Created people are handed to the crowd system, which is the only thing that draws and steps
## them. Resolved by group for the same reason as the simulation: an unattached reference would
## silently place markers with nobody standing on them.
func _crowd() -> CrowdSystem:
	if crowd == null:
		crowd = get_tree().get_first_node_in_group("crowd")
	return crowd


func _projected_tris() -> int:
	return _budget.projected(String(_tpl()["id"]))


func _rebuild_ghost() -> void:
	for k in _ghost.get_children():
		(k as Node).free()
	var ctx := ChunkCtx.new()
	ctx.setup(7)
	ctx.detail = true
	var t := _tpl_scaled(obj_scale)
	BuildTemplates.build(ctx, t, BuildTemplates.rect(Vector2.ZERO, Vector2(t["size"]), 0.0), 0.5)
	for f in [ctx.buildings, ctx.props, ctx.emissive]:
		if f.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = f.commit()
		mi.material_overlay = _ghost_mat
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


## The only entry point for new world content, so a player click and an AI generator cannot
## take different paths past the validator.
func place(c: Vector2) -> int:
	_reason = _validate(c)
	if _reason != Validation.Reason.OK:
		GameGlobals.say("不能建造：%s" % Validation.label(_reason))
		return -1
	var id := next_id
	next_id += 1
	var t := _tpl()
	var st := {"id": id, "tpl": String(t["id"]), "x": c.x, "z": c.y,
		"yaw": yaw, "scale": obj_scale}
	if String(t["kind"]) == "npc":
		# The identity travels with the record, so a reload recreates the same person rather
		# than a random stranger standing at the same coordinate.
		st["name"] = String(t["name"])
		st["occ"] = int(t["occ"])
	# Through _put, not around it: that is where the economy learns that a business exists, and
	# a second insertion path would let a click place something the ledger never sees.
	_put(st)
	_undo.append({"op": "add", "obj": st.duplicate()})
	_redo.clear()
	changed.emit()
	return id


## Two clicks lay a segment: the first anchors it, the second commits. A preview line is kept
## between them so the player sees the road they are about to make.
func road_click(c: Vector2) -> int:
	if _road_a == null:
		_road_a = c
		GameGlobals.say("道路：起点已定，再点一次确定终点（右键取消）")
		return -1
	var a: Vector2 = _road_a
	_road_a = null
	if a.distance_to(c) < 12.0:
		GameGlobals.say("道路太短，至少 12 m")
		return -1
	var mid := (a + c) * 0.5
	_reason = Validation.check(mid, a.distance_to(c) * 0.5, _near_centers(), streamer,
		_budget.total() + BuildTemplates.road_cost(a, c, 12.0))
	if _reason != Validation.Reason.OK:
		GameGlobals.say("不能建造：%s" % Validation.label(_reason))
		return -1
	var id := next_id
	next_id += 1
	var st := {"id": id, "tpl": "road", "x": a.x, "z": a.y,
		"x2": c.x, "z2": c.y, "yaw": 0.0, "scale": 1.0, "width": 12.0}
	_store(st)
	_undo.append({"op": "add", "obj": st.duplicate()})
	_redo.clear()
	changed.emit()
	return id


func _near_centers() -> Array:
	var near: Array = []
	for k in objects.keys():
		var st: Dictionary = objects[k]
		near.append(Vector2(float(st["x"]), float(st["z"])))
	return near


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
	var ctx := ChunkCtx.new()
	ctx.setup(11)
	ctx.detail = true
	if String(st["tpl"]) == "road":
		# Roads are anchored at their start point, so the segment is built in node-local
		# space and the whole thing stays movable by editing one transform.
		BuildTemplates.build_road(ctx, Vector2.ZERO,
			Vector2(float(st["x2"]), float(st["z2"])) - c, float(st["width"]))
	else:
		var t: Dictionary = _tpl_of(String(st["tpl"]), sc)
		BuildTemplates.build(ctx, t,
			BuildTemplates.rect(Vector2.ZERO, Vector2(t["size"]), 0.0), _seed_of(id))
	var bags := [
		[ctx.buildings, Assets.facade_mat(), true],
		[ctx.props, Assets.props_mat(), true],
		[ctx.streets, Assets.road_mat(2, true, 12.5), false],
		[ctx.plates, Assets.ground_mat(), false],
		[ctx.emissive, Assets.emissive_mat(), false]]
	var tris := 0
	for pair in bags:
		var f: MeshFusion = pair[0]
		tris += f.tri_count()
		if f.is_empty():
			continue
	# Recorded per object rather than estimated from the template, because a road's cost is its
	# length and a scaled tower's is not its unscaled catalogue entry.
	st["tris"] = tris
	for pair in bags:
		var f: MeshFusion = pair[0]
		if f.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = f.commit()
		mi.material_overlay = pair[1]
		mi.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if pair[2]
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
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
	## Selecting an object follows its template, and templates live in two palettes, so the
	## tool has to move with the selection — otherwise Tab after picking a bench would cycle
	## towers and the next placement would not be the thing the player was looking at.
	var is_prop := String(BuildTemplates.find(String(st["tpl"]))["kind"]) == "prop"
	if is_prop and tool != Tool.DECOR:
		_set_tool(Tool.DECOR)
	elif not is_prop and tool == Tool.DECOR:
		_set_tool(Tool.BUILDING)
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
	var pal := _pal()
	for i in pal.size():
		if String(pal[i]["id"]) == tpl_id:
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
	_business.destroy(id, sim)
	if crowd != null:
		crowd.unpin(id)
	_budget.remove(id)
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
	if String(st["tpl"]) == "road":
		var w := float(st.get("width", 12.0))
		st["z"] = float(st["z"]) + w + 6.0
		st["z2"] = float(st["z2"]) + w + 6.0
	else:
		var t := _tpl_of(String(st["tpl"]), float(st["scale"]))
		st["x"] = float(st["x"]) + Vector2(t["size"]).x * 0.75
	_store(st)
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
	_store(after)
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


## The single place an object record becomes scene geometry. Every mutation path — click,
## duplicate, edit, undo, reload — goes through here, so the economy cannot be told about a
## shop by one path and not by another.
func _store(st: Dictionary) -> void:
	var id := int(st["id"])
	objects[id] = (st as Dictionary).duplicate()
	_realize(objects[id])
	var t := int(objects[id].get("tris", 0))
	_budget.add(id, t)
	_sim()
	_business.store(objects[id], sim)
	if String(BuildTemplates.find(String(st["tpl"]))["kind"]) == "npc":
		_crowd().pin(objects[id])


func _put(st: Dictionary) -> void:
	_store(st)
	if selected == int(st["id"]):
		select(int(st["id"]))


func _payload() -> Dictionary:
	var arr: Array = []
	for k in objects.keys():
		arr.append(objects[k])
	arr.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	return {"objects": arr, "next_id": next_id}


## Godot's JSON parser hands back every number as a float, so a record that went out with
## id=1 comes back as id=1.0 and a reloaded save is no longer identical to the one written.
## Normalising on the way in makes local and server reloads agree, and keeps ids usable as
## dictionary keys across sessions.
static func _normalize(raw: Dictionary) -> Dictionary:
	var st := raw.duplicate()
	st["id"] = int(st.get("id", 0))
	st["tpl"] = String(st.get("tpl", ""))
	st["x"] = float(st.get("x", 0.0))
	st["z"] = float(st.get("z", 0.0))
	st["yaw"] = float(st.get("yaw", 0.0))
	st["scale"] = float(st.get("scale", 1.0))
	if st.has("name"):
		st["name"] = String(st["name"])
	if st.has("occ"):
		st["occ"] = int(st["occ"])
	for k in ["x2", "z2", "width"]:
		if st.has(k):
			st[k] = float(st[k])
	return st


func _apply_payload(p: Dictionary) -> int:
	clear_all()
	next_id = maxi(next_id, int(p.get("next_id", 1)))
	var n := 0
	for raw in p.get("objects", []):
		var st := _normalize(raw)
		var id := int(st["id"])
		_store(st)
		next_id = maxi(next_id, id + 1)
		n += 1
	return n


## Mirrors the just-written local cache to the server. Deliberately not awaited by callers:
## a save must never block the editor on network latency.
func mirror_save() -> void:
	if backend == null or not backend.online:
		return
	var ok: bool = await backend.save(_payload())
	if ok:
		GameGlobals.say("已同步到服务器")
	else:
		GameGlobals.say("服务器同步失败（本地存档已保留）：%s" % backend.last_error)


## Pulls the server copy over the local one. Reports corruption recovery, because the server
## rolls back a damaged generation on its own and the player should know it happened.
func pull_save() -> int:
	if backend == null or not backend.online:
		return -1
	var r: Dictionary = await backend.load_save()
	if not bool(r["ok"]):
		GameGlobals.say("读取服务器存档失败：%s" % String(r.get("error", "")))
		return -1
	if bool(r["absent"]):
		return 0
	var n := _apply_payload(r["payload"])
	if bool(r["recovered"]):
		GameGlobals.say("服务器检测到存档损坏，已自动回退到上一代（%d 件作品）" % n)
	return n


## End-to-end proof that the client and the backend agree on a save round-trip: place,
## mirror, wipe memory, pull back, compare. Run with --backend-sync-test.
func sync_roundtrip_test() -> bool:
	var fails := 0
	clear_all()
	_reason = Validation.Reason.OK
	var placed := 0
	var ring := 0
	while placed < 3 and ring < 400:
		for j in 400:
			var p := Vector2(-4500.0 + float(ring) * 13.0, -4500.0 + float(j) * 13.0)
			if _validate(p) != Validation.Reason.OK:
				continue
			if place(p) >= 0:
				placed += 1
			if placed >= 3:
				break
		ring += 1
	if placed < 3:
		print("[sync] FAIL  only placed %d objects, cannot test round-trip" % placed)
		return false
	var before := JSON.stringify(_payload())
	var pushed: bool = await backend.save(_payload())
	if not pushed:
		print("[sync] FAIL  mirror_save  %s" % backend.last_error)
		fails += 1
	clear_all()
	var pulled := await pull_save()
	if pulled != 3:
		print("[sync] FAIL  pull returned %d (want 3)" % pulled)
		fails += 1
	var after := JSON.stringify(_payload())
	if before != after:
		print("[sync] FAIL  payload differs after round-trip")
		print("        before=%s" % before)
		print("        after =%s" % after)
		fails += 1
	var bal := await backend.balance()
	if bal < 0:
		print("[sync] FAIL  balance not readable")
		fails += 1
	else:
		print("[sync] server balance = %d (服务器计算，客户端无权设定)" % bal)
	clear_all()
	return fails == 0


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
	mirror_save()
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
	# Same normalisation as the server path, so a local reload and a cloud reload cannot
	# produce two different object sets from one save.
	var n := _apply_payload(parsed)
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
	_budget.clear()
	# Bypasses _destroy, so every registration has to be released here or a cleared city would
	# keep employing staff for shops that no longer exist.
	_business.clear(_sim())
	if crowd != null:
		crowd.unpin_all()
	changed.emit()


func stats() -> Dictionary:
	var has_cursor := _cursor != Vector2(INF, INF)
	var z: int = CreationZones.zone_at(_cursor) if has_cursor else CreationZones.Zone.PRIVATE
	return {"objects": objects.size(), "selected": selected, "tool": tool,
		"tpl": String(_tpl()["name"]), "undo": _undo.size(), "redo": _redo.size(),
		"active": active, "reason": Validation.label(_reason),
		"zone": CreationZones.label(z),
		"zone_max": CreationZones.max_half(_cursor) if has_cursor else 0.0,
		"tris": _budget.total(), "tris_max": Validation.MAX_TRIS,
		"ok": _reason == Validation.Reason.OK, "road_pending": _road_a != null}


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
				tpl_i = (tpl_i + 1) % _pal().size()
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
			var p := _ground_point()
			if tool == Tool.ROAD:
				var rid := road_click(p)
				if rid >= 0:
					select(rid)
				get_viewport().set_input_as_handled()
				return
			var hit_id := pick()
			if event.ctrl_pressed and hit_id >= 0:
				remove(hit_id)
			elif hit_id >= 0:
				select(hit_id)
			else:
				select(place(p))
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_road_a = null
			select(-1)
			get_viewport().set_input_as_handled()


func _set_tool(t: int) -> void:
	tool = t
	_road_a = null
	_ghost_key = ""
	var pal := _pal()
	tpl_i = clampi(tpl_i, 0, pal.size() - 1)
	if t == Tool.ROAD:
		GameGlobals.say("道路工具 — 点两次成一段（车道 + 人行道 + 路灯），右键取消")
	elif t == Tool.DECOR:
		GameGlobals.say("装饰工具 — %d 种街道构件，Tab 换构件（构件按真实尺寸放置，不参与缩放）"
			% pal.size())
	elif t == Tool.NPC:
		GameGlobals.say("NPC 工具 — %d 种身份，Tab 换身份；创建的人不参与人群预算" % pal.size())
	elif _todo_tools.has(t):
		GameGlobals.say("%s — 待实现（当前可用：建筑、道路、装饰、NPC）" % String(_todo_tools[t]))
	else:
		GameGlobals.say("工具：建筑 — Tab 换模板，共 %d 种" % pal.size())


func _process(_delta: float) -> void:
	if not active:
		return
	if camera == null or not is_instance_valid(camera):
		camera = get_viewport().get_camera_3d() as Camera3D
		if camera == null:
			return
	var p := _ground_point()
	if tool == Tool.ROAD:
		_update_road_ghost(p)
		return
	if selected >= 0:
		_ghost.visible = false
		return
	_ghost.visible = true
	_update_ghost(p)


## The road tool reuses the same preview node: before the second click it shows nothing, and
## after it shows the segment that is about to be committed.
func _update_road_ghost(p: Vector2) -> void:
	if _road_a == null:
		_ghost.visible = false
		_reason = Validation.Reason.OK
		return
	_ghost.visible = true
	var a: Vector2 = _road_a
	var key := "road|%d|%d" % [int(round(a.x)), int(round(a.y))]
	if p.distance_to(a) < 12.0:
		_reason = Validation.Reason.OVERLAP
	elif key != _ghost_key:
		_ghost_key = key
		_rebuild_road_ghost(a, p)
		_reason = Validation.Reason.OK
	_ghost.position = Vector3.ZERO
	_ghost.rotation = Vector3.ZERO


func _rebuild_road_ghost(a: Vector2, b: Vector2) -> void:
	for k in _ghost.get_children():
		(k as Node).free()
	var ctx := ChunkCtx.new()
	ctx.setup(7)
	ctx.detail = true
	BuildTemplates.build_road(ctx, a, b, 12.0)
	for f in [ctx.streets, ctx.plates, ctx.props, ctx.emissive]:
		if f.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = f.commit()
		mi.material_overlay = _ghost_mat
		_ghost.add_child(mi)
