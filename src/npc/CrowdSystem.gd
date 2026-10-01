class_name CrowdSystem
extends Node3D
## Pedestrian crowds on MultiMeshInstance3D — the Mass-AI equivalent. Each agent is a real
## NPCProfile with a job, a home and a day plan; movement is greedy navigation along the
## implicit street graph toward wherever that plan says they should be.
##
## Three AI tiers, per the population-simulation design:
##   tier 0  <  70 m  needs integrate, plan re-resolves, the person is nameable
##   tier 1  < 460 m  navigation and planning only, needs frozen
##   tier 2  beyond   no individual at all — PopulationSystem's district census covers it
##
## Two poses stand in for a walk cycle: splitting the crowd across two instances and
## alternating by stride phase reads as walking at the distances crowds are seen at.

const SIDEWALK := 1.35
const SPAWN_RADIUS := 260.0
const POSE_HZ := 1.45
const TIER0 := 70.0
const TIER1 := 460.0
const ARRIVE_R := 115.0

var agents: Array = []
var pinned: Array = []		# player-created residents; never subject to the budget
var budget := 260
var sim: CitySim
var sim_radius := 700.0
var focus := Vector3.ZERO
var pop: PopulationSystem
var hour: float = 9.0
var rain: float = 0.0

var _pose_a: MultiMeshInstance3D
var _pose_b: MultiMeshInstance3D
var _rng := RandomNumberGenerator.new()
var _hidden: int = 0
var _next_id: int = 1


func _ready() -> void:
	add_to_group("crowd")
	_rng.seed = 0xC0FFEE
	_pose_a = _make_pose(0)
	_pose_b = _make_pose(1)
	add_child(_pose_a)
	add_child(_pose_b)
	pop = get_tree().get_first_node_in_group("population")
	sim = get_tree().get_first_node_in_group("sim")


func _make_pose(pose: int) -> MultiMeshInstance3D:
	var mi := MultiMeshInstance3D.new()
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	m.use_colors = true
	m.mesh = _human_mesh(pose)
	mi.multimesh = m
	mi.material_override = Assets.props_mat(false)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.extra_cull_margin = 60.0
	# MultiMesh does not refresh its AABB as instance transforms change, so an auto-computed
	# bounds culls the entire crowd. A generous fixed bound is the standard workaround.
	mi.custom_aabb = AABB(Vector3(-3000, -20, -3000), Vector3(6000, 80, 6000))
	return mi


static func _human_mesh(pose: int) -> ArrayMesh:
	var f := MeshFusion.new()
	var skin := Color(0.78, 0.62, 0.52)
	skin.a = 0.0
	var coat := Color(0.55, 0.55, 0.58)
	coat.a = 0.0
	var trouser := Color(0.22, 0.22, 0.26)
	trouser.a = 0.0
	f.ellipsoid(Transform3D(Basis.IDENTITY, Vector3(0, 1.60, 0)),
		Vector3(0.115, 0.13, 0.115), skin, 5, 7)
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 0.96, 0)),
		Vector3(0.40, 0.66, 0.24), coat)
	var swing := 0.20 if pose == 0 else -0.20
	for s in [-1, 1]:
		var off := swing * float(s)
		f.box(Transform3D(Basis.IDENTITY, Vector3(0.19 * s, 0.98, off * 0.45)),
			Vector3(0.11, 0.60, 0.11), coat)
		f.box(Transform3D(Basis.IDENTITY, Vector3(0.10 * s, 0.36, off)),
			Vector3(0.14, 0.72, 0.15), trouser)
	return f.commit()


func apply_quality(c: Dictionary) -> void:
	budget = int(c["npc_budget"])
	sim_radius = maxf(float(c["sim_radius"]) * GameGlobals.CHUNK_SIZE, 400.0)


func set_clock(h: float, rain_now: float) -> void:
	hour = h
	rain = rain_now


func _process(delta: float) -> void:
	if GameGlobals.game_mode == GameGlobals.GameMode.BUILD:
		return
	if focus == Vector3.ZERO or pop == null:
		return
	_near_t -= delta
	var share := pop.active_share(hour)
	# District footfall comes from the city simulation. Without it the crowd is a formula
	# of the clock; with it an empty high street is a consequence of shops closing.
	var sim_f := 1.0
	if sim != null:
		sim_f = sim.crowd_factor_at(Vector2(focus.x, focus.z))
	var want := int(budget * share * sim_f)
	while agents.size() < want:
		var ag := {}
		_seed(ag)
		agents.append(ag)
	while agents.size() > want:
		agents.pop_back()
	var ta: Array[Transform3D] = []
	var tb: Array[Transform3D] = []
	var ca: Array[Color] = []
	var cb: Array[Color] = []
	_hidden = 0
	for li in 2:
		# Budget agents and player-created ones are stepped and drawn by the same code; the
		# only difference is which list they live in, so there is no second NPC path to drift.
		var list: Array = agents if li == 0 else pinned
		for ag in list:
			_step(ag, delta)
			var prof: NPCProfile = ag["prof"]
			if ag["hidden"]:
				_hidden += 1
				continue
			var xform := _transform(ag)
			if int(prof.id) % 2 == 0:
				ta.append(xform)
				ca.append(ag["col"])
			else:
				tb.append(xform)
				cb.append(ag["col"])
	# Stride phase picks the pose, so a crowd does not march in lockstep.
	var swap := int(Time.get_ticks_msec() / (1000.0 / POSE_HZ)) % 2
	if swap == 1:
		_flush(_pose_a, tb, cb)
		_flush(_pose_b, ta, ca)
	else:
		_flush(_pose_a, ta, ca)
		_flush(_pose_b, tb, cb)


func _flush(inst: MultiMeshInstance3D, list: Array, cols: Array) -> void:
	var m := inst.multimesh
	if m.instance_count != list.size():
		m.instance_count = list.size()
	for i in list.size():
		m.set_instance_transform(i, list[i])
		m.set_instance_color(i, cols[i])


func _step(ag: Dictionary, delta: float) -> void:
	var prof: NPCProfile = ag["prof"]
	var here := Vector2(focus.x, focus.z)
	var d := Vector2(ag["pos"].x - here.x, ag["pos"].y - here.y).length()
	ag["tier"] = 0 if d < TIER0 else (1 if d < TIER1 else 2)
	if d > sim_radius:
		if ag.has("owner"):
			# A resident the player created stays where they were put. Re-seeding them near
			# the camera would make every visit teleport the people you made.
			ag["hidden"] = true
			return
		_seed(ag)
		return
	# Re-planning resolves a goal position, which samples the pools — so it is throttled
	# rather than run every frame for every agent.
	var cadence := 0.7 if ag["tier"] == 0 else 4.0
	ag["plan_t"] = float(ag.get("plan_t", 0.0)) - delta
	if ag["plan_t"] <= 0.0 or ag["tier"] == 0 and prof.goal == Vector2.ZERO:
		ag["plan_t"] = cadence
		prof.plan(hour, rain, pop)
	if ag["tier"] == 0:
		prof.tick(delta * 26.0, prof.state == OccupationTable.State.WORK)
	var a := Lattice.cell_center(ag["node"].x, ag["node"].y)
	var b := Lattice.cell_center(ag["target"].x, ag["target"].y)
	var seg := b - a
	var l := maxf(seg.length(), 0.001)
	var dir := seg / l
	ag["t"] = float(ag["t"]) + float(ag["speed"]) * delta / l
	ag["pos"] = a.lerp(b, clampf(ag["t"], 0.0, 1.0)) + Vector2(-dir.y, dir.x) * float(ag["side"])
	ag["dir"] = dir
	ag["hidden"] = false
	if ag["t"] >= 1.0:
		ag["node"] = ag["target"]
		_arrive(ag)


## Reached a street node: either finish the journey (indoors, so stop drawing them) or
## take the next hop toward the current goal.
func _arrive(ag: Dictionary) -> void:
	var prof: NPCProfile = ag["prof"]
	var node: Vector2i = ag["node"]
	var nc := Lattice.cell_center(node.x, node.y)
	if nc.distance_to(prof.goal) < ARRIVE_R:
		if prof.state == OccupationTable.State.WORK or prof.state == OccupationTable.State.SLEEP:
			ag["hidden"] = true
			ag["t"] = 0.0
			ag["target"] = node
			return
		# Leisure and shopping mean strolling: keep moving along a random adjacent street.
		ag["target"] = _hop(node, nc + Vector2(_rng.randf_range(-220, 220), _rng.randf_range(-220, 220)))
		ag["t"] = 0.0
		return
	ag["target"] = _hop(node, prof.goal)
	ag["t"] = 0.0
	_restyle(ag)


## Greedy best-improvement hop. On a 74 %-dense warped grid this reaches goals reliably;
## when no neighbour improves, fall back to a random hop rather than deadlocking.
func _hop(node: Vector2i, goal: Vector2) -> Vector2i:
	var opts := Lattice.neighbors(node)
	if opts.is_empty():
		return node
	var best: Vector2i = node
	var bd := 1e18
	var ties: Array = []
	for o in opts:
		var c := Lattice.cell_center(o.x, o.y)
		var dd := c.distance_to(goal)
		if dd < bd - 0.001:
			bd = dd
			best = o
			ties.clear()
			ties.append(o)
		elif absf(dd - bd) < 0.001:
			ties.append(o)
	var cur := Lattice.cell_center(node.x, node.y)
	if bd >= cur.distance_to(goal) - 1.0:
		return opts[_rng.randi_range(0, opts.size() - 1)]
	return ties[_rng.randi_range(0, ties.size() - 1)]


func _restyle(ag: Dictionary) -> void:
	var prof: NPCProfile = ag["prof"]
	match prof.state:
		OccupationTable.State.COMMUTE:
			ag["speed"] = 1.62 + _rng.randf() * 0.35
		OccupationTable.State.EXERCISE:
			ag["speed"] = 1.85 + _rng.randf() * 0.6
		OccupationTable.State.LEISURE:
			ag["speed"] = 0.95 + _rng.randf() * 0.35
		OccupationTable.State.SHOP:
			ag["speed"] = 1.25 + _rng.randf() * 0.3
		_:
			ag["speed"] = 1.2 + _rng.randf() * 0.4


func _transform(ag: Dictionary) -> Transform3D:
	var p: Vector2 = ag["pos"]
	var d: Vector2 = ag["dir"]
	var yaw := atan2(-d.x, d.y) + float(ag["sway"])
	var s: float = ag["scale"]
	return Transform3D(Basis.IDENTITY.scaled(Vector3(s, s, s)).rotated(Vector3.UP, yaw),
		Vector3(p.x, 0.0, p.y))


## Put an agent on a real street near `center`, within `radius`. Returns false when no
## carriageway was found in the attempts, so the caller decides what a failure means: a budget
## agent gets parked and retried, a player-created one is reported as not placed.
func _place(ag: Dictionary, center: Vector2, radius: float) -> bool:
	for attempt in 12:
		var ang := _rng.randf() * TAU
		var rad := pow(_rng.randf(), 2.2) * radius
		var p := center + Vector2(cos(ang), sin(ang)) * rad
		var hit := Lattice.random_edge_near(p, 3, _rng)
		if hit.is_empty():
			continue
		var node: Vector2i = hit["node"]
		var tgt: Vector2i = hit["target"]
		var w := Lattice.edge_of(node, tgt)
		var prof := NPCProfile.create(_next_id, _rng, pop, p)
		_next_id += 1
		ag["prof"] = prof
		ag["node"] = node
		ag["target"] = tgt
		ag["t"] = _rng.randf()
		ag["side"] = (w * 0.5 + SIDEWALK) * (1.0 if _rng.randf() > 0.5 else -1.0)
		ag["scale"] = 0.90 + prof.age / 100.0 * 0.22
		ag["speed"] = 1.3
		ag["tier"] = 1
		ag["plan_t"] = _rng.randf() * 0.6
		ag["sway"] = _rng.randf_range(-0.22, 0.22)
		ag["hidden"] = false
		var c := OccupationTable.dress_color(prof.occ, _rng)
		c.a = 0.0
		ag["col"] = c
		var a0 := Lattice.cell_center(node.x, node.y)
		var b0 := Lattice.cell_center(tgt.x, tgt.y)
		var d0 := (b0 - a0).normalized()
		ag["pos"] = a0.lerp(b0, ag["t"]) + Vector2(-d0.y, d0.x) * ag["side"]
		ag["dir"] = d0
		return true
	return false


## No street found: hold the agent off-map so it retries next frame rather than piling up on
## the camera.
func _park(ag: Dictionary) -> void:
	ag["prof"] = NPCProfile.new()
	ag["node"] = Vector2i(9999, 9999)
	ag["target"] = Vector2i(9999, 9999)
	ag["t"] = 0.0
	ag["side"] = SIDEWALK
	ag["scale"] = 1.0
	ag["speed"] = 1.3
	ag["tier"] = 2
	ag["sway"] = 0.0
	ag["hidden"] = true
	ag["pos"] = Vector2(focus.x, focus.z) + Vector2(9000.0, 9000.0)
	ag["dir"] = Vector2.UP
	var cc := Color(0.3, 0.3, 0.34)
	cc.a = 0.0
	ag["col"] = cc


## Put an agent on a real street near the viewer, with a resident assigned to it.
func _seed(ag: Dictionary) -> void:
	if _place(ag, Vector2(focus.x, focus.z), SPAWN_RADIUS):
		return
	_park(ag)


# --- Player-created residents ------------------------------------------------
## Someone the editor placed is not part of the budget: they are never evicted when the crowd
## thins, they keep the name and occupation the player gave them, and they are seeded where they
## were placed rather than near whoever is looking. They are stepped and drawn by the same code
## as budget agents, so there is no second NPC renderer to drift out of sync.
func pin(st: Dictionary) -> bool:
	var ag := {}
	if not _place(ag, Vector2(float(st["x"]), float(st["z"])), 24.0):
		_park(ag)
	var prof: NPCProfile = ag["prof"]
	if st.has("name"):
		prof.display_name = String(st["name"])
	if st.has("occ"):
		prof.occ = int(st["occ"])
	ag["owner"] = int(st["id"])
	ag["plan_t"] = 0.0
	pinned.append(ag)
	return not ag["hidden"]


func unpin(obj_id: int) -> void:
	for i in pinned.size():
		if int(pinned[i].get("owner", -1)) == obj_id:
			pinned.remove_at(i)
			return


func unpin_all() -> void:
	pinned.clear()


func has_pinned(obj_id: int) -> bool:
	for ag in pinned:
		if int(ag.get("owner", -1)) == obj_id:
			return true
	return false


## The closest pedestrian, for the HUD and for whatever interaction system consumes them.
## Scanning every agent each frame is pure waste — this refreshes four times a second.
var _near_cache: Dictionary = {}
var _near_t: float = 0.0


func nearest() -> Dictionary:
	if not _near_cache.is_empty() and _near_t > 0.0:
		return _near_cache
	var best := 1e18
	var out: Dictionary = {}
	for li in 2:
		var list: Array = agents if li == 0 else pinned
		for ag in list:
			if ag.has("prof") and not ag.get("hidden", true):
				var p: Vector2 = ag["pos"]
				var d := Vector2(p.x - focus.x, p.y - focus.z).length()
				if d < best:
					best = d
					out = ag
	_near_t = 0.25
	_near_cache = {"agent": out, "dist": best if best < 1e17 else -1.0}
	return _near_cache


func stats() -> Dictionary:
	var n := nearest()
	var drawn := _pose_a.multimesh.instance_count + _pose_b.multimesh.instance_count
	var t0 := 0
	for ag in agents:
		if ag.get("tier", 2) == 0:
			t0 += 1
	return {"agents": agents.size() + pinned.size(), "drawn": drawn, "hidden": _hidden,
		"pinned": pinned.size(), "near": float(n["dist"]), "who": n["agent"], "tier0": t0}
