class_name ChunkBuilder
extends RefCounted
## Turns one 250 m world-partition cell into merged render surfaces plus collision.
##
## Assignment is geometric, never list-based: a street belongs to the chunk containing its
## midpoint, a block belongs to the chunk containing its centroid. That means no chunk can
## double-draw or miss a feature, and loading order is irrelevant.

const STEP := 25.0
const ROAD_Y := 0.05
const BED_Y := -13.0
const BANK_FALLOFF := 14.0
const LAMP_SPACING := 34.0
const TREE_SPACING := 19.0


static var _prof: Dictionary = {}


static func profile_totals() -> Dictionary:
	return _prof


static func build(chunk: Vector2i, detail: bool, ground_step: float = STEP) -> ChunkCtx:
	var ctx := ChunkCtx.new()
	ctx.setup(GameGlobals.hash2(chunk.x, chunk.y, 909) * 1e9 + 7)
	ctx.detail = detail
	var s := GameGlobals.CHUNK_SIZE
	var min_p := Vector2(chunk.x * s - s * 0.5, chunk.y * s - s * 0.5)
	var max_p := min_p + Vector2(s, s)
	var t0 := Time.get_ticks_usec()
	# The ground grid exists before the block pass so each block can paint its own slots.
	var n := int(s / ground_step)
	ctx.begin_ground(min_p, n, ground_step)
	# Blocks first: the ground grid needs their plate regions to colour itself correctly.
	_blocks(ctx, chunk)
	var t1 := Time.get_ticks_usec()
	_streets(ctx, chunk, min_p, max_p, detail)
	var t2 := Time.get_ticks_usec()
	_ground(ctx, min_p)
	var t3 := Time.get_ticks_usec()
	if detail:
		_furniture(ctx, chunk, min_p, max_p)
	var t4 := Time.get_ticks_usec()
	for pair in [["blocks", t1 - t0], ["streets", t2 - t1], ["ground", t3 - t2],
			["furniture", t4 - t3]]:
		var k: String = pair[0]
		_prof[k] = int(_prof.get(k, 0)) + int(pair[1])
	# One sample per chunk build: counting it per phase divides every average by four.
	_prof["n"] = int(_prof.get("n", 0)) + 1
	return ctx


# --- Ground and riverbed ----------------------------------------------------
static func _ground(ctx: ChunkCtx, min_p: Vector2) -> void:
	var n := ctx.ground_n
	var step := ctx.ground_step
	var cx := PackedFloat32Array()
	var cz := PackedFloat32Array()
	for i in range(n + 1):
		cx.append(min_p.x + float(i) * step)
		cz.append(min_p.y + float(i) * step)
	# The river distance answers both questions below — how high the terrain sits and which
	# surface colours it — so it is resolved once per grid node instead of once per query.
	var t0 := Time.get_ticks_usec()
	var wd: PackedFloat32Array = PackedFloat32Array()
	wd.resize((n + 1) * (n + 1))
	for i in range(n + 1):
		for j in range(n + 1):
			wd[j * (n + 1) + i] = CityData.water_dist_q(Vector2(cx[i], cz[j]))
	var t1 := Time.get_ticks_usec()
	var ys := PackedFloat32Array()
	ys.resize(wd.size())
	for k in wd.size():
		var d: float = wd[k]
		ys[k] = 0.0 if d >= CityData.BANK_FALLOFF else (CityData.BANK_Y if d <= 0.0
			else lerpf(CityData.BANK_Y, 0.0, pow(d / CityData.BANK_FALLOFF, 0.62)))
	var t2 := Time.get_ticks_usec()
	# Slots still unpainted after the block pass hold open ground: no block owns that point,
	# so its surface comes from parks, avenues and district character.
	var natural := 0
	for i in range(n):
		for j in range(n):
			var k := j * n + i
			var dd: float = wd[j * (n + 1) + i]
			if dd < 2.0:
				ctx.ground_cols[k] = _mk(Color(0.115, 0.115, 0.105), CellProgram.CODE_MUD)
			elif dd < BANK_FALLOFF:
				ctx.ground_cols[k] = _mk(Color(0.30, 0.285, 0.245), CellProgram.CODE_MUD)
			elif (ctx.ground_cols[k] as Color).a < 0.0:
				var centre := Vector2((cx[i] + cx[i + 1]) * 0.5, (cz[j] + cz[j + 1]) * 0.5)
				ctx.ground_cols[k] = _natural_col(centre)
				natural += 1
	_acc("g_natural", natural)
	var t3 := Time.get_ticks_usec()
	for i in range(n):
		for j in range(n):
			var a := Vector3(cx[i], ys[j * (n + 1) + i], cz[j])
			var b := Vector3(cx[i + 1], ys[j * (n + 1) + i + 1], cz[j])
			var c := Vector3(cx[i + 1], ys[(j + 1) * (n + 1) + i + 1], cz[j + 1])
			var d := Vector3(cx[i], ys[(j + 1) * (n + 1) + i], cz[j + 1])
			var col: Color = ctx.ground_cols[j * n + i]
			var nrm := (b - a).cross(d - a).normalized()
			if nrm.y < 0.0:
				nrm = -nrm
			ctx.plates.quad(a, b, c, d, nrm, col)
	var t4 := Time.get_ticks_usec()
	for pair in [["g_water", t1 - t0], ["g_height", t2 - t1], ["g_colour", t3 - t2],
			["g_emit", t4 - t3]]:
		var k: String = pair[0]
		_prof[k] = int(_prof.get(k, 0)) + int(pair[1])


## Natural ground where no block owns the point. Block plates are already in the slot grid,
## so this is the only classification left to do per sample.
static func _natural_col(p: Vector2) -> Color:
	var t1 := Time.get_ticks_usec()
	if CityData.in_park(p):
		_acc("sc_fields", int(Time.get_ticks_usec() - t1))
		return _mk(Color(0.16, 0.23, 0.10), CellProgram.CODE_GRASS)
	var gap: float = CityData.major_gap(p)
	var inten := CityData.intensity_q(p)
	var style := CityData.district_style(p)
	_acc("sc_fields", int(Time.get_ticks_usec() - t1))
	if gap < 30.0 and inten > 0.34:
		return _mk(Color(0.355, 0.35, 0.345), CellProgram.CODE_CONC)
	if style == "suburb" or style == "rural":
		return _mk(Color(0.29, 0.275, 0.235), CellProgram.CODE_GRASS)
	if style == "port_industry":
		return _mk(Color(0.30, 0.295, 0.29), CellProgram.CODE_TRACK)
	return _mk(Color(0.245, 0.255, 0.215), CellProgram.CODE_GROUND)


static func _acc(key: String, us: int) -> void:
	_prof[key] = int(_prof.get(key, 0)) + us


static func _mk(c: Color, code: float) -> Color:
	var out := c
	out.a = code
	return out


# --- Local streets (dual-graph edges) ---------------------------------------
static func _streets(ctx: ChunkCtx, chunk: Vector2i, min_p: Vector2, max_p: Vector2,
		include_drive: bool) -> void:
	var cells := Lattice.cells_in_rect(min_p, max_p, GameGlobals.CHUNK_SIZE * 0.5)
	var asphalt := Color(0.0, 0.0, 0.0)
	asphalt.a = CellProgram.CODE_GROUND
	for cij in cells:
		var c: Vector2i = cij
		for axis in 2:
			if not Lattice.edge_present(c.x, c.y, axis):
				continue
			var a := Lattice.cell_center(c.x, c.y)
			var nb := c + (Vector2i(1, 0) if axis == 0 else Vector2i(0, 1))
			var b := Lattice.cell_center(nb.x, nb.y)
			var mid := (a + b) * 0.5
			if mid.x < min_p.x or mid.x > max_p.x or mid.y < min_p.y or mid.y > max_p.y:
				continue
			var w := Lattice.edge_width(c.x, c.y, axis)
			var pts := PackedVector2Array([a, b])
			# Extend past the node so intersections close up.
			var dir := (b - a).normalized()
			pts[0] = a - dir * (w * 0.5)
			pts[1] = b + dir * (w * 0.5)
			ctx.streets.ribbon(pts, w * 0.5, ROAD_Y, ROAD_Y, asphalt, MeshFusion.arc_lengths(pts))
			if ctx.detail:
				_dashes(ctx, pts[0], pts[1], w)
			if include_drive:
				ctx.drive_points.append({"p": mid, "dir": dir, "w": w, "a": pts[0], "b": pts[1]})


## Centre lines are geometry rather than a shader feature, because the asphalt material is
## shared by every local street in the chunk and cannot carry per-street markings.
static func _dashes(ctx: ChunkCtx, a: Vector2, b: Vector2, w: float) -> void:
	var l := a.distance_to(b)
	if l < 20.0 or w < 10.0:
		return
	var dir := (b - a).normalized()
	var white := Color(0.78, 0.77, 0.72)
	white.a = CellProgram.CODE_GROUND
	var n := int(l / 9.0)
	for k in n:
		if k % 2 == 1:
			continue
		var p0 := a + dir * (float(k) / float(n) * l)
		var p1 := a + dir * ((float(k) + 0.62) / float(n) * l)
		var seg := PackedVector2Array([p0, p1])
		ctx.streets.ribbon(seg, 0.09, ROAD_Y + 0.014, ROAD_Y + 0.014, white,
			MeshFusion.arc_lengths(seg))


# --- Blocks -----------------------------------------------------------------
static func _blocks(ctx: ChunkCtx, chunk: Vector2i) -> void:
	var s := GameGlobals.CHUNK_SIZE
	var lo := Vector2(chunk.x * s - s * 0.5, chunk.y * s - s * 0.5)
	var hi := lo + Vector2(s, s)
	# Every block that overlaps this chunk registers its paving, because the ground grid
	# has to know what surface sits under cells owned by a neighbour. Only the chunk that
	# owns a block's centre emits its buildings, so nothing is ever drawn twice.
	for cij in Lattice.cells_in_rect(lo, hi, s * 0.55):
		var c: Vector2i = cij
		var cc := Lattice.cell_center(c.x, c.y)
		var owned := cc.x >= lo.x and cc.x <= hi.x and cc.y >= lo.y and cc.y <= hi.y
		CellProgram.build_cell(ctx, c.x, c.y, owned)


# --- Street furniture -------------------------------------------------------
static func _furniture(ctx: ChunkCtx, chunk: Vector2i, min_p: Vector2, max_p: Vector2) -> void:
	var steel := Color(0.30, 0.31, 0.33)
	steel.a = CellProgram.CODE_CONC
	var count := 0
	for dp in ctx.drive_points:
		if count > 26:
			break
		var a: Vector2 = dp["a"]
		var b: Vector2 = dp["b"]
		var dir: Vector2 = dp["dir"]
		var w: float = dp["w"]
		var l := a.distance_to(b)
		if l < 26.0:
			continue
		var n := clampi(int(l / LAMP_SPACING), 1, 6)
		var side := 1.0 if (chunk.x + chunk.y) % 2 == 0 else -1.0
		for k in n:
			var t := (float(k) + 0.5) / float(n)
			var p := a.lerp(b, t) + Vector2(-dir.y, dir.x) * (w * 0.5 + 1.6) * side
			if p.x < min_p.x - 8.0 or p.x > max_p.x + 8.0 or p.y < min_p.y - 8.0 or p.y > max_p.y + 8.0:
				continue
			# Broad-phase the river on the quantised field, exact only inside its error band.
			if CityData.major_gap(p) < 3.0:
				continue
			if CityData.water_dist_q(p) < STEP and CityData.in_water(p):
				continue
				continue
			_lamp(ctx, p, dir, steel)
			count += 1
		var tn := clampi(int(l / TREE_SPACING), 1, 8)
		for k in tn:
			if k % 2 == 1:
				continue
			var t2 := (float(k) + 0.5) / float(tn)
			var q := a.lerp(b, t2) + Vector2(-dir.y, dir.x) * (w * 0.5 + 2.2) * -side
			if q.x < min_p.x or q.x > max_p.x or q.y < min_p.y or q.y > max_p.y:
				continue
			if CityData.major_gap(q) < 2.5:
				continue
			if CityData.water_dist_q(q) < STEP and CityData.in_water(q):
				continue
				continue
			CellProgram.tree(ctx, q, 0.85 + GameGlobals.hash2(k, chunk.x, 707) * 0.55,
				GameGlobals.hash2(k, chunk.y, 708))


static func _lamp(ctx: ChunkCtx, p: Vector2, dir: Vector2, steel: Color) -> void:
	var hgt := 8.4
	var xf := Transform3D(Basis.IDENTITY, Vector3(p.x, 0.0, p.y))
	ctx.props.cylinder(xf, 0.16, 0.10, hgt, steel, 6, false)
	var arm := Vector2(-dir.y, dir.x) * 1.5
	ctx.props.box(Transform3D(Basis.IDENTITY, Vector3(p.x + arm.x * 0.5, hgt - 0.2, p.y + arm.y * 0.5)),
		Vector3(1.7, 0.16, 0.16), steel)
	ctx.emissive.box(Transform3D(Basis.IDENTITY, Vector3(p.x + arm.x, hgt - 0.55, p.y + arm.y)),
		Vector3(0.95, 0.30, 0.42), Color(1.0, 0.84, 0.60))
