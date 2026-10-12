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
## A pedestrian is four poses deep and each one is picked by that person's own stride phase, so a
## crowd of four hundred does not walk in lockstep. See STRIDE_POSES below for why this is a
## per-agent quantity and not a clock.

const SIDEWALK := 1.35
const SPAWN_RADIUS := 260.0
const TIER0 := 70.0
const TIER1 := 460.0
const ARRIVE_R := 115.0

## Four poses per stride, selected by each agent's own accumulated gait phase rather than by a
## global clock. The previous version swapped two poses for the whole crowd on one timer, so every
## pedestrian on screen moved their legs at the same instant - which is not "walking at crowd
## distance", it is a marching band. Per-agent phase also lets stride rate follow walking speed,
## so a commuter's legs actually move faster than a stroller's while both keep the same stride.
const STRIDE_POSES := 4
## Gait advance per metre per second of travel: 2.9 poses/s at 1.3 m/s is ~0.95 stride cycles a
## second, which is a normal adult cadence, and the same constant makes an exercised agent's legs
## turn over faster without anyone tuning a second number.
const GAIT_PER_MPS := 2.9

## [left leg, left knee, right leg, right knee, left arm, right arm] in radians.
## Legs swing about the hip; the knee angle is how far the shin trails the thigh, so a bent knee
## on the back leg is the push-off and on the forward leg is the heel strike.
const PHASE := [
	[0.40, 0.06, -0.40, 0.34, -0.30, 0.30],
	[0.06, 0.02, 0.36, 0.72, -0.04, -0.32],
	[-0.40, 0.34, 0.40, 0.06, 0.30, -0.30],
	[0.36, 0.72, 0.06, 0.02, -0.32, -0.04],
]

var agents: Array = []
var pinned: Array = []		# player-created residents; never subject to the budget
var budget := 260
var sim: CitySim
var sim_radius := 700.0
var focus := Vector3.ZERO
var pop: PopulationSystem
var hour: float = 9.0
var rain: float = 0.0

var _poses: Array = []		# one MultiMeshInstance3D per stride phase
var _rng := RandomNumberGenerator.new()
var _hidden: int = 0
var _next_id: int = 1


func _ready() -> void:
	add_to_group("crowd")
	_rng.seed = 0xC0FFEE
	for p in STRIDE_POSES:
		var mi := _make_pose(p)
		_poses.append(mi)
		add_child(mi)
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


## A hanging segment. `MeshFusion.box` grows upward from its origin, so a limb that drops toward
## the ground is the same box rotated pi about X - and measuring the angle from there means a swing
## of 0 is straight down, positive is forward, and the joint arithmetic below stays legible.
static func _hang(from: Vector3, ang: float) -> Transform3D:
	return Transform3D(Basis.IDENTITY.rotated(Vector3.RIGHT, PI - ang), from)


static func _tip(from: Vector3, ang: float, len: float) -> Vector3:
	return from + Vector3(0.0, -cos(ang) * len, sin(ang) * len)


static func _col(r: float, g: float, b: float) -> Color:
	var c := Color(r, g, b)
	c.a = 0.0
	return c


## One limb, two segments, one joint. The single-box-per-limb version this replaced kept the knee
## and elbow straight through every phase of the step, so the pedestrian read as a gliding
## mannequin; at crowd distance the silhouette is the whole read, and a bending joint is most of it.
static func _limb(f: MeshFusion, root: Vector3, a0: float, a1: float, l0: float, l1: float,
		w: float, d: float, c0: Color, c1: Color) -> void:
	f.box(_hang(root, a0), Vector3(w, l0, d), c0)
	var mid := _tip(root, a0, l0)
	f.box(_hang(mid, a1), Vector3(w * 0.86, l1, d * 0.86), c1)


## The body, built for one of four stride phases. Two-segment legs with a foot, two-segment arms
## swinging opposite to their own side's leg, and a hair cap, because a crowd of heads with no
## hair reads as a crowd of balls.
static func _human_mesh(pose: int) -> ArrayMesh:
	var f := MeshFusion.new()
	var ph: Array = PHASE[pose % PHASE.size()]
	var skin := _col(0.78, 0.62, 0.52)
	var coat := _col(0.55, 0.55, 0.58)
	var trouser := _col(0.22, 0.22, 0.26)
	var dark := _col(0.115, 0.115, 0.135)
	f.ellipsoid(Transform3D(Basis.IDENTITY, Vector3(0, 1.585, 0)),
		Vector3(0.105, 0.125, 0.105), skin, 4, 6)
	f.ellipsoid(Transform3D(Basis.IDENTITY, Vector3(0, 1.648, -0.010)),
		Vector3(0.108, 0.072, 0.108), dark, 2, 6)
	## Chest and pelvis in different tones: one box for the whole trunk erases the waist, and the
	## waist is where the eye decides a shape is a person.
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 1.055, 0)), Vector3(0.375, 0.40, 0.225), coat)
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 0.875, 0)), Vector3(0.325, 0.185, 0.205), trouser)
	for s in [-1, 1]:
		var leg := float(ph[0]) if s < 0 else float(ph[2])
		var knee := float(ph[1]) if s < 0 else float(ph[3])
		var hip := Vector3(0.085 * s, 0.90, 0.0)
		_limb(f, hip, leg, leg - knee, 0.44, 0.42, 0.15, 0.165, trouser, trouser)
		var ankle := _tip(hip, leg - knee, 0.42)
		f.box(Transform3D(Basis.IDENTITY, ankle + Vector3(0, -0.055, 0.055)),
			Vector3(0.105, 0.055, 0.235), dark)
		var arm := float(ph[4]) if s < 0 else float(ph[5])
		var sh := Vector3(0.185 * s, 1.425, 0.0)
		_limb(f, sh, arm, arm - 0.34, 0.295, 0.265, 0.108, 0.115, coat, coat)
		f.box(Transform3D(Basis.IDENTITY, _tip(sh, arm - 0.34, 0.265)),
			Vector3(0.085, 0.075, 0.09), skin)
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
	# One bucket per stride phase; the phase is the agent's own, so no two people share a beat.
	var xforms: Array = []
	var cols: Array = []
	for p in STRIDE_POSES:
		xforms.append([])
		cols.append([])
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
			xforms[int(ag["gait"]) % STRIDE_POSES].append(_transform(ag))
			cols[int(ag["gait"]) % STRIDE_POSES].append(ag["col"])
	for p in STRIDE_POSES:
		_flush(_poses[p], xforms[p], cols[p])


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
	ag["gait"] = int(float(ag.get("gait", 0.0)) + float(ag["speed"]) * delta * GAIT_PER_MPS)
	## Phase 257: a corner everybody wants is a corner that moves slowly, and the crowd is what
	## makes it wanted. Read at the position they are leaving from, then published at the one they
	## reached, so nobody is slowed by a crush that only their own step created.
	var slow := sim.slow_at(ag["pos"]) if sim != null else 1.0
	ag["t"] = float(ag["t"]) + float(ag["speed"]) * delta * slow / l
	ag["pos"] = a.lerp(b, clampf(ag["t"], 0.0, 1.0)) + Vector2(-dir.y, dir.x) * float(ag["side"])
	if sim != null:
		sim.publish_walk(ag["pos"], delta)
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
		ag["gait"] = _rng.randi_range(0, STRIDE_POSES - 1)
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
	ag["gait"] = 0
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



## Drawn across all four stride instances.
func _drawn() -> int:
	var n := 0
	for mi in _poses:
		n += (mi as MultiMeshInstance3D).multimesh.instance_count
	return n


func stats() -> Dictionary:
	var n := nearest()
	var drawn := _drawn()
	var t0 := 0
	for ag in agents:
		if ag.get("tier", 2) == 0:
			t0 += 1
	return {"agents": agents.size() + pinned.size(), "drawn": drawn, "hidden": _hidden,
		"pinned": pinned.size(), "near": float(n["dist"]), "who": n["agent"], "tier0": t0}
