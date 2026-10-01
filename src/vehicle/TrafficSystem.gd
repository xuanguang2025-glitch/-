class_name TrafficSystem
extends Node3D
## AI traffic on the same implicit street graph as the crowd. Cars are MultiMesh instances
## with a kinematic lane-follow model — right-hand running, speed modulated by time of day
## and weather, and a forward-gap check that produces queueing at merge points without a
## full vehicle dynamics solve.
##
## A real VehicleBody3D per AI car would cost the frame budget that the city itself needs;
## Mass-AI-style agents plus one draw call per vehicle type is the trade actually made here.

const LANE_FRACTION := 0.26
const SPAWN_RADIUS := 340.0
var cars: Array = []
var budget := 60
var sim_radius := 900.0
var focus := Vector3.ZERO
var night := 0.0
var wet := 0.0
var sim: CitySim

var _sedan: MultiMeshInstance3D
var _cabin: MultiMeshInstance3D
var _bus: MultiMeshInstance3D
var _lamps: MultiMeshInstance3D
var _rng := RandomNumberGenerator.new()
var _rush: float = 0.25


func _ready() -> void:
	add_to_group("traffic")
	sim = get_tree().get_first_node_in_group("sim")
	_rng.seed = 0x7A7E
	_sedan = _make(_sedan_mesh(), Assets.props_mat(false), true)
	_cabin = _make(_cabin_mesh(), Assets.std(Color(0.05, 0.06, 0.08), 0.08, 0.2), false)
	_bus = _make(_bus_mesh(), Assets.props_mat(false), true)
	_lamps = _make(_lamp_mesh(), Assets.emissive_mat(), false)
	_lamps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sedan)
	add_child(_bus)
	add_child(_cabin)
	add_child(_lamps)


func _make(mesh: Mesh, mat: Material, shadow: bool) -> MultiMeshInstance3D:
	var mi := MultiMeshInstance3D.new()
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	m.use_colors = true
	m.mesh = mesh
	mi.multimesh = m
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 80.0
	# Same MultiMesh AABB caveat as the crowd: bounds do not track moving instances.
	mi.custom_aabb = AABB(Vector3(-3000, -20, -3000), Vector3(6000, 120, 6000))
	return mi


static func _sedan_mesh() -> ArrayMesh:
	var f := MeshFusion.new()
	var c := Color(1, 1, 1)
	c.a = 0.0
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 0.42, 0)), Vector3(1.84, 0.72, 4.45), c)
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 0.30, 0)), Vector3(1.70, 0.34, 4.20), c)
	return f.commit()


static func _cabin_mesh() -> ArrayMesh:
	var f := MeshFusion.new()
	var c := Color(1, 1, 1)
	c.a = 0.0
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 1.02, -0.18)), Vector3(1.62, 0.56, 2.14), c)
	return f.commit()


static func _bus_mesh() -> ArrayMesh:
	var f := MeshFusion.new()
	var c := Color(1, 1, 1)
	c.a = 0.0
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 1.35, 0)), Vector3(2.50, 2.70, 10.8), c)
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 0.42, 0)), Vector3(2.36, 0.60, 10.6), c)
	return f.commit()


static func _lamp_mesh() -> ArrayMesh:
	var f := MeshFusion.new()
	var c := Color(1, 0.92, 0.76)
	for s in [-1, 1]:
		f.box(Transform3D(Basis.IDENTITY, Vector3(0.62 * s, 0.52, 2.12)),
			Vector3(0.42, 0.20, 0.10), c)
	return f.commit()


func apply_quality(c: Dictionary) -> void:
	budget = int(c["vehicle_budget"])
	sim_radius = maxf(float(c["sim_radius"]) * GameGlobals.CHUNK_SIZE, 600.0)


## Shanghai traffic is bimodal: 07:30–09:30 and 17:00–19:30 are gridlock, 03:00 is empty.
func set_time_factor(hour: float) -> void:
	var f := 0.22
	for peak in [[8.5, 1.0], [17.8, 1.0], [12.5, 0.62], [21.5, 0.42]]:
		var d := absf(hour - float(peak[0]))
		if d < 2.6:
			f = maxf(f, float(peak[1]) * (1.0 - d / 2.6))
	if hour < 5.5 or hour > 23.2:
		f = 0.05
	_rush = f


## Vehicles the district under the viewer wants, from the city's ride demand. Dry weather
## resolves to exactly 1.0, so this is invisible until demand actually moves.
func _sim_cars() -> float:
	return sim.car_factor_at(Vector2(focus.x, focus.z)) if sim != null else 1.0


func _process(delta: float) -> void:
	if GameGlobals.game_mode == GameGlobals.GameMode.BUILD:
		return
	if focus == Vector3.ZERO:
		return
	# Rain used to remove cars here; the simulation says rain buys rides, so the old term was
	# a second, contradictory model of the same weather. Wetness still costs speed below.
	var want := mini(budget, int(budget * _rush * _sim_cars()))
	while cars.size() < want:
		var ag := {}
		_recruit(ag)
		cars.append(ag)
	while cars.size() > want:
		cars.pop_back()
	# Forward gap check: cheap O(n²) at this population, and it is what makes queues form.
	for a in cars:
		var gap := 1e9
		for b in cars:
			if a == b:
				continue
			var ahead: Vector2 = b["pos"] - a["pos"]
			var d: Vector2 = a["dir"]
			var along := ahead.dot(d)
			if along > 0.5 and along < 22.0 and absf(ahead.dot(Vector2(-d.y, d.x))) < 3.2:
				gap = minf(gap, along)
		a["gap"] = gap
	var ts: Array[Transform3D] = []
	var cs: Array[Color] = []
	var tb: Array[Transform3D] = []
	var cb: Array[Color] = []
	var tc: Array[Transform3D] = []
	var tl: Array[Transform3D] = []
	for car in cars:
		_step(car, delta)
		var xf := _transform(car)
		if car["is_bus"]:
			tb.append(xf)
			cb.append(car["col"])
		else:
			ts.append(xf)
			cs.append(car["col"])
			tc.append(xf.translated_local(Vector3(0, 0, 0)))
			if night > 0.35:
				tl.append(xf)
	_flush(_sedan, ts, cs)
	_flush(_bus, tb, cb)
	_flush(_cabin, tc, cs)
	_flush(_lamps, tl, [])


func _flush(inst: MultiMeshInstance3D, list: Array, cols: Array) -> void:
	var m := inst.multimesh
	if m.instance_count != list.size():
		m.instance_count = list.size()
	for i in list.size():
		m.set_instance_transform(i, list[i])
		if cols.size() == list.size():
			m.set_instance_color(i, cols[i])


func _step(car: Dictionary, delta: float) -> void:
	var a := Lattice.cell_center(car["node"].x, car["node"].y)
	var b := Lattice.cell_center(car["target"].x, car["target"].y)
	var seg := b - a
	var l := maxf(seg.length(), 0.001)
	var dir := seg / l
	car["dir"] = dir
	var cruise: float = car["cruise"] * (1.0 - 0.3 * wet)
	var target_speed := cruise
	# Queue behind whatever is in front, and crawl through the heaviest rush hour.
	var gap: float = car["gap"]
	if gap < 18.0:
		target_speed = minf(target_speed, maxf((gap - 5.0) * 1.1, 0.6))
	if _rush > 0.85:
		target_speed *= 0.62
	car["speed"] = move_toward(float(car["speed"]), target_speed, delta * 5.5)
	car["t"] = float(car["t"]) + float(car["speed"]) * delta / l
	if car["t"] >= 1.0:
		car["node"] = car["target"]
		car["target"] = _next(car["node"], car["target"])
		car["t"] = 0.0
	var lane := float(car["lane"])
	car["pos"] = a.lerp(b, clampf(car["t"], 0.0, 1.0)) + Vector2(-dir.y, dir.x) * lane
	if Vector2(car["pos"].x - focus.x, car["pos"].y - focus.z).length_squared() \
			> sim_radius * sim_radius:
		_recruit(car)


func _next(node: Vector2i, came_from: Vector2i) -> Vector2i:
	var opts := Lattice.neighbors(node)
	if opts.is_empty():
		return came_from
	var fwd: Array = []
	for o in opts:
		if o != came_from:
			fwd.append(o)
	var pool := fwd if (not fwd.is_empty() and _rng.randf() > 0.18) else opts
	return pool[_rng.randi_range(0, pool.size() - 1)]


func _transform(car: Dictionary) -> Transform3D:
	var d: Vector2 = car["dir"]
	var p: Vector2 = car["pos"]
	var yaw := atan2(d.x, -d.y)
	var s: float = car["scale"]
	return Transform3D(Basis.IDENTITY.scaled(Vector3(s, s, s)).rotated(Vector3.UP, yaw),
		Vector3(p.x, 0.0, p.y))


func _recruit(car: Dictionary) -> void:
	for attempt in 14:
		var ang := _rng.randf() * TAU
		# Same bias as the crowd: uniform-in-area placement leaves the street in front empty.
		var rad := pow(_rng.randf(), 2.0) * SPAWN_RADIUS
		var p := Vector2(focus.x, focus.z) + Vector2(cos(ang), sin(ang)) * rad
		var hit := Lattice.random_edge_near(p, 4, _rng)
		if hit.is_empty():
			continue
		var node: Vector2i = hit["node"]
		var tgt: Vector2i = hit["target"]
		var w := Lattice.edge_of(node, tgt)
		if w < 9.0:
			continue
		car["node"] = node
		car["target"] = tgt
		car["t"] = _rng.randf()
		car["is_bus"] = _rng.randf() > 0.88
		car["scale"] = 1.0
		var base := 11.0 if not car["is_bus"] else 8.5
		car["cruise"] = base * (0.72 + _rng.randf() * 0.5)
		car["speed"] = car["cruise"] * 0.6
		car["gap"] = 1e9
		var a0 := Lattice.cell_center(node.x, node.y)
		var d0 := (Lattice.cell_center(tgt.x, tgt.y) - a0).normalized()
		# Right-hand running: the lane offset flips with direction of travel.
		car["lane"] = w * LANE_FRACTION
		car["pos"] = a0.lerp(Lattice.cell_center(tgt.x, tgt.y), car["t"]) \
			+ Vector2(-d0.y, d0.x) * car["lane"]
		car["dir"] = d0
		var pal := [Color(0.78, 0.79, 0.81), Color(0.10, 0.11, 0.13), Color(0.36, 0.05, 0.05),
			Color(0.06, 0.14, 0.32), Color(0.55, 0.56, 0.54), Color(0.02, 0.42, 0.36),
			Color(0.86, 0.80, 0.22), Color(0.14, 0.14, 0.16)]
		if car["is_bus"]:
			pal = [Color(0.10, 0.30, 0.62), Color(0.72, 0.44, 0.06), Color(0.16, 0.44, 0.24)]
		var c: Color = pal[_rng.randi_range(0, pal.size() - 1)]
		c.a = 0.0
		car["col"] = c
		return
	# No carriageway found: park the car outside the sim radius so it retries next frame
	# rather than piling up on the camera.
	car["node"] = Vector2i(9999, 9999)
	car["target"] = Vector2i(9999, 9999)
	car["t"] = 0.0
	car["is_bus"] = false
	car["scale"] = 1.0
	car["cruise"] = 10.0
	car["speed"] = 0.0
	car["gap"] = 1e9
	car["lane"] = 3.0
	car["pos"] = Vector2(focus.x, focus.z) + Vector2(9000.0, 9000.0)
	car["dir"] = Vector2.UP
	var cc := Color(0.5, 0.5, 0.52)
	cc.a = 0.0
	car["col"] = cc


func stats() -> Dictionary:
	return {"cars": cars.size(), "drawn": _sedan.multimesh.instance_count
		+ _bus.multimesh.instance_count, "rush": _rush, "placed": _placed()}


func _placed() -> int:
	var n := 0
	for c in cars:
		if c["node"].x < 9000:
			n += 1
	return n
