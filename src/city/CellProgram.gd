class_name CellProgram
extends RefCounted
## Twelve Shanghai block archetypes. This is what makes the city read as Shanghai rather
## than a random grid: 住宅小区 walled estates, 弄堂 lanes, 沿街商业 street frontages,
## podium-and-setback towers, 老公房 walk-up rows, factory halls with chimneys.
##
## Pure writes into ChunkCtx, so a distant LOD pass can call the same code with
## ctx.detail = false and get a cheap silhouette instead of a second generator.

const GY := 0.02
const CODE_GROUND := 0.0
const CODE_GRASS := 1.0
const CODE_PAVE := 2.0
const CODE_PLAZA := 3.0
const CODE_CONC := 4.0
const CODE_TRACK := 5.0
const CODE_MUD := 6.0
const CODE_DECK := 7.0


# --- Outline helpers --------------------------------------------------------
static func centroid(q: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in q:
		c += p
	return c / float(maxi(q.size(), 1))


static func inset(q: PackedVector2Array, m: float) -> PackedVector2Array:
	var c := centroid(q)
	var out := PackedVector2Array()
	for p in q:
		var v := p - c
		var l := maxf(v.length(), 0.001)
		out.append(c + v * maxf(l - m, 1.0) / l)
	return out


static func long_axis(q: PackedVector2Array) -> Vector2:
	var best := Vector2.RIGHT
	var bl := 0.0
	for i in q.size():
		var d := q[(i + 1) % q.size()] - q[i]
		if d.length_squared() > bl:
			bl = d.length_squared()
			best = d
	return best.normalized() if best.length_squared() > 0.0001 else Vector2.RIGHT


static func frame_of(q: PackedVector2Array) -> BlockFrame:
	var c := centroid(q)
	var ax := long_axis(q)
	var az := Vector2(-ax.y, ax.x)
	var ex := 0.0
	var ez := 0.0
	for p in q:
		var v := p - c
		ex = maxf(ex, absf(v.dot(ax)))
		ez = maxf(ez, absf(v.dot(az)))
	return BlockFrame.new().make(c, maxf(ex, 6.0), maxf(ez, 6.0), ax)


static func col(code: float, c: Color) -> Color:
	var out := c
	out.a = code
	return out


# --- Cell facts -------------------------------------------------------------
## A block cell is read by up to four neighbouring chunks — once to build it and once per
## ground-grid sample on each shared edge. Resolving its classification, style, intensity,
## height band and randoms a single time collapses that overlap.
class CellFacts extends RefCounted:
	var center: Vector2
	var usable: bool = false
	var kind: String = ""
	var style: String = ""
	var intensity: float = 0.0
	var code: float = -1.0
	var plate: Color = Color(0, 0, 0, -1)
	var hmin: float = 6.0
	var hmax: float = 30.0
	var r1: float = 0.0
	var r2: float = 0.0
	var r3: float = 0.0


static var _facts: Dictionary = {}


static func facts(i: int, j: int) -> CellFacts:
	var ck := Vector2i(i, j)
	if _facts.has(ck):
		return _facts[ck]
	var f := CellFacts.new()
	f.center = Lattice.cell_center(i, j)
	f.usable = not CityData.blocks_building(f.center, -6.0) \
		and CityData.major_gap(f.center) >= -2.0 \
		and not CityData.in_landmark_zone(f.center)
	if not f.usable:
		_facts[ck] = f
		return f
	f.kind = Lattice.cell_kind(i, j)
	f.style = CityData.district_style(f.center)
	f.intensity = CityData.intensity_q(f.center)
	var hr := CityData.height_range_at(f.center)
	f.hmin = hr.x
	f.hmax = hr.y
	f.r1 = GameGlobals.hash2(i, j, 301)
	f.r2 = GameGlobals.hash2(i, j, 302)
	f.r3 = GameGlobals.hash2(i, j, 303)
	f.code = kind_code(f.kind, f.style)
	f.plate = plate_color(f.code, f.r1)
	f.plate.a = f.code
	_facts[ck] = f
	return f


# --- Dispatcher -------------------------------------------------------------
static func build_cell(ctx: ChunkCtx, i: int, j: int, build: bool = true) -> void:
	var f := facts(i, j)
	if not f.usable:
		return
	ctx.cell_count += 1

	var quad := Lattice.cell_quad(i, j)
	var kind := f.kind
	var style := f.style
	var intensity := f.intensity
	var r1 := f.r1
	var r2 := f.r2
	var r3 := f.r3
	ctx.rng.seed = int(GameGlobals.hash2(i, j, 411) * 1e9)

	plate_block(ctx, quad, f.code, style, r1)
	ctx.paint_plate(quad, f.plate)
	if not build:
		return
	ctx.mark_occupied(quad, 12.0)

	var fr := frame_of(quad)
	var tint := Assets.tint_for(style, r2)
	var hmax := f.hmax

	match kind:
		"SPLIT_TOWER":
			tower(ctx, quad, tint, clampf(lerpf(hmax * 0.45, hmax, r3) * (0.7 + 0.5 * intensity), 30.0, 420.0), r1)
		"OFFICE_PLINTH":
			plinth_tower(ctx, quad, tint, clampf(lerpf(hmax * 0.5, hmax, r3) * (0.6 + 0.6 * intensity), 26.0, 260.0), r1)
		"XIAOQU":
			var fl: int = [6, 11, 11, 18, 18][int(r3 * 4.999) % 5]
			if intensity > 0.62:
				fl = [11, 14, 18, 26, 33][int(r3 * 4.999) % 5]
			xiaoqu(ctx, quad, tint, fl, r1)
		"DENSE_WALKUP":
			walkup_rows(ctx, quad, tint, [5, 6, 6, 7, 8][int(r3 * 4.999) % 5], r1)
		"LILONG":
			lilong(ctx, quad, tint, r1, r3)
		"SHOPFRONT_ROW":
			shopfront(ctx, quad, tint, r1, r2, intensity)
		"MALL":
			mall(ctx, quad, tint, clampf(16.0 + r3 * 26.0, 14.0, 44.0), r1)
		"FACTORY":
			factory(ctx, quad, tint, r1, r2, style)
		"VILLAS":
			villas(ctx, quad, r1)
		"PARKING":
			parking_lot(ctx, quad, r1)
		"PARK_CELL":
			park(ctx, quad, r1, r2)
		"SITE":
			site(ctx, quad, tint, clampf(hmax * (0.35 + r3 * 0.6), 18.0, 160.0), r1)
		_:
			tower(ctx, quad, tint, 30.0, r1)
	ctx.tri_total += ctx.totals()


# --- Block plate ------------------------------------------------------------
static func plate_color(code: float, r: float) -> Color:
	match code:
		CODE_GRASS:
			return Color(0.155, 0.215, 0.105).lerp(Color(0.285, 0.315, 0.155), r)
		CODE_PAVE:
			return [Color(0.400, 0.392, 0.385), Color(0.500, 0.482, 0.455),
				Color(0.340, 0.342, 0.360), Color(0.560, 0.535, 0.485)][int(r * 3.99) % 4]
		CODE_PLAZA:
			return [Color(0.585, 0.555, 0.500), Color(0.470, 0.462, 0.455),
				Color(0.650, 0.620, 0.560)][int(r * 2.99) % 3]
		CODE_TRACK:
			return Color(0.300, 0.295, 0.290).lerp(Color(0.430, 0.412, 0.385), r)
		CODE_DECK:
			return Color(0.360, 0.340, 0.320)
		_:
			return Color(0.375, 0.368, 0.355).lerp(Color(0.470, 0.455, 0.425), r)


## Records that this block owns ground. The paving colour itself is recomputed per ground
## cell from the block index, so chunks never disagree about a shared point.
static func kind_code(kind: String, style: String) -> float:
	match kind:
		"PARK_CELL":
			return CODE_GRASS
		"FACTORY", "PARKING":
			return CODE_TRACK
		"SITE":
			return CODE_DECK
		"MALL", "OFFICE_PLINTH":
			return CODE_PLAZA
		"VILLAS":
			if style == "suburb" or style == "rural" or style == "diplomatic":
				return CODE_GRASS
			return CODE_PAVE
		_:
			return CODE_PAVE


# --- Block builders ---------------------------------------------------------


static func plate_block(ctx: ChunkCtx, quad: PackedVector2Array, code: float,
		style: String, r: float) -> void:
	ctx.spawn_points.append(centroid(quad))


static func kerb(ctx: ChunkCtx, quad: PackedVector2Array) -> void:
	if not ctx.detail:
		return
	var c := centroid(quad)
	var kc := plate_color(CODE_CONC, 0.5)
	kc.a = CODE_CONC
	for i in quad.size():
		var a := quad[i]
		var b := quad[(i + 1) % quad.size()]
		var dir := b - a
		var l := dir.length()
		if l < 5.0:
			continue
		var n := Vector2(-dir.y, dir.x) / l
		if (c - (a + b) * 0.5).dot(n) > 0.0:
			n = -n
		var ox := n.x
		var oz := n.y
		var e := 0.34
		ctx.plates.quad(
			Vector3(a.x + ox * e, 0.0, a.y + oz * e),
			Vector3(b.x + ox * e, 0.0, b.y + oz * e),
			Vector3(b.x + ox * e, 0.17, b.y + oz * e),
			Vector3(a.x + ox * e, 0.17, a.y + oz * e),
			Vector3(ox, 0.0, oz), kc)


# --- Tower family -----------------------------------------------------------
static func tower(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color, h: float, r: float) -> void:
	var f := frame_of(quad)
	var plot := inset(quad, 5.0)
	var pod_h := clampf(h * 0.13, 5.0, 16.0)
	if h > 26.0:
		ctx.buildings.prism(plot, GY, pod_h, tint, 1.0)
		box_collider(ctx, plot, GY, pod_h)
	var shaft := inset(plot, minf(f.ex, f.ez) * 0.24)
	var rest := maxf(h - pod_h, 6.0)
	var segs := 1
	if rest > 80.0:
		segs = 2
	if rest > 170.0:
		segs = 3
	if rest > 300.0:
		segs = 4
	var y := pod_h
	var cur := shaft
	var shrink := 0.05 + 0.05 * r
	for s in segs:
		var frac := 0.55 if s == 0 else 1.0 / float(maxi(segs - s, 1))
		var sh := maxf(rest * clampf(frac, 0.16, 0.6), 5.0)
		ctx.buildings.prism(cur, y, y + sh, tint, 1.0 - shrink, deg_to_rad((r - 0.5) * 5.0))
		box_collider(ctx, cur, y, y + sh)
		var sc := centroid(cur)
		var nxt := PackedVector2Array()
		for p in cur:
			nxt.append(sc + (p - sc) * (1.0 - shrink))
		cur = inset(nxt, 0.8)
		y += sh
		shrink *= 0.7
	crown(ctx, cur, y, h, r)
	roof_clutter(ctx, cur, y, r)
	kerb(ctx, quad)


static func plinth_tower(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color,
		h: float, r: float) -> void:
	var f := frame_of(quad)
	var ph := clampf(6.0 + r * 10.0, 5.0, 18.0)
	var plinth := inset(quad, 4.0)
	ctx.buildings.prism(plinth, GY, ph, tint, 1.0)
	box_collider(ctx, plinth, GY, ph)
	var shaft := inset(plinth, minf(f.ex, f.ez) * 0.34)
	ctx.buildings.prism(shaft, ph, h, tint, 0.84, deg_to_rad((r - 0.5) * 8.0))
	box_collider(ctx, shaft, ph, h)
	crown(ctx, shaft, h, h, r)
	roof_clutter(ctx, shaft, h, r)
	kerb(ctx, quad)


static func crown(ctx: ChunkCtx, q: PackedVector2Array, y: float, h: float, r: float) -> void:
	var f := frame_of(q)
	var rr := minf(f.ex, f.ez)
	if h > 220.0:
		ctx.buildings.prism(inset(q, rr * 0.25), y, y + 24.0 + r * 40.0,
			Color(0.48, 0.52, 0.57), 0.34)
		var mast_y := y + 24.0 + r * 40.0
		ctx.props.cylinder(Transform3D(Basis.IDENTITY, Vector3(f.c.x, mast_y, f.c.y)),
			0.9, 0.2, 42.0, col(CODE_CONC, Color(0.70, 0.70, 0.72)), 6, false)
		ctx.emissive.add_primitive(Assets.sphere(1.6, 8),
			Transform3D(Basis.IDENTITY, Vector3(f.c.x, mast_y + 43.0, f.c.y)),
			Color(1.0, 0.12, 0.08))
	elif h > 90.0:
		ctx.buildings.prism(inset(q, rr * 0.18), y, y + 8.0 + r * 22.0,
			Color(0.44, 0.47, 0.52), 0.62)
		if ctx.detail:
			ctx.emissive.prism(inset(q, rr * 0.30), y + 3.0, y + 5.0,
				col(CODE_PLAZA, Color(0.15, 0.45, 0.95)), 1.02)
	elif h > 34.0:
		ctx.props.box(Transform3D(Basis.IDENTITY, Vector3(f.c.x, y, f.c.y)),
			Vector3(f.ex * 1.8, 3.0, f.ez * 1.8), col(CODE_CONC, Color(0.46, 0.46, 0.48)))


# --- Residential ------------------------------------------------------------
## 住宅小区: walled perimeter, identical point slabs in rows around a courtyard.
static func xiaoqu(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color,
		floors: int, r: float) -> void:
	var f := frame_of(quad)
	perimeter_wall(ctx, quad, r)
	var fh := 2.95
	var h := float(floors) * fh
	# Rows and point-slab widths are expressed as half-extents, which is what BlockFrame.rect
	# takes; the pitch below keeps a courtyard between the rows.
	var rows := 2 if f.ex < 58.0 else 3
	var per_row := clampi(int(2 + r * 3.6), 2, 5)
	var pitch_z := f.ez * 1.70 / float(rows)
	var depth := minf(pitch_z * 0.34, 9.5)
	var pitch_x := f.ex * 1.84 / float(per_row)
	for row in rows:
		var z_off := -f.ez * 0.85 + (float(row) + 0.5) * pitch_z
		for k in per_row:
			var x_off := -f.ex * 0.92 + (float(k) + 0.5) * pitch_x
			var hw := clampf(pitch_x * (0.30 + GameGlobals.hash2(k, row, 55) * 0.14), 4.0, 17.0)
			var q := f.rect(x_off, z_off, hw, depth, 0.0)
			var rc := tint
			rc.a = 0.0
			residential_slab(ctx, q, h, rc, floors, GameGlobals.hash2(k, row, 56))
	if ctx.detail and rows > 1:
		for t in 4:
			var p := f.at((GameGlobals.hash2(t, 3, 57) - 0.5) * f.ex * 1.4,
				(GameGlobals.hash2(t, 4, 58) - 0.5) * f.ez * 0.5)
			tree(ctx, p, 0.7 + GameGlobals.hash2(t, 5, 59) * 0.7, GameGlobals.hash2(t, 6, 60))
	kerb(ctx, quad)


static func residential_slab(ctx: ChunkCtx, q: PackedVector2Array, h: float,
		tint: Color, floors: int, r: float) -> void:
	var f := frame_of(q)
	var fh := h / float(maxi(floors, 1))
	ctx.buildings.prism(q, GY, h, tint, 1.0)
	box_collider(ctx, q, GY, h)
	# Balcony bands on the front face — the shaded slabs every Shanghai block has.
	if ctx.detail and floors >= 6:
		var bc := col(CODE_CONC, Color(0.60, 0.565, 0.505))
		var n := mini(floors - 1, 14)
		for fidx in n:
			var y := GY + fh * (float(fidx) + 0.50)
			for side in [-1, 1]:
				if side > 0 and r < 0.42:
					continue
				var a := f.at(-f.ex * 0.88, f.ez * float(side))
				var b := f.at(f.ex * 0.88, f.ez * float(side))
				var o := f.az * (0.42 * float(side))
				ctx.props.quad(Vector3(b.x + o.x, y, b.y + o.y), Vector3(a.x + o.x, y, a.y + o.y),
					Vector3(a.x + o.x, y + fh * 0.55, a.y + o.y),
					Vector3(b.x + o.x, y + fh * 0.55, b.y + o.y),
					Vector3(f.az.x * float(side), 0.0, f.az.y * float(side)), bc)
	# Ground-floor shopfront strip on residential podiums.
	ctx.emissive.prism(q, GY, GY + minf(3.4, h * 0.28), col(CODE_CONC, Color(0.22, 0.21, 0.23)), 1.02)
	roof_clutter(ctx, q, h, r)


## 老公房 rows: 5-8 storey bars, two units deep, ground floor shops.
static func walkup_rows(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color,
		floors: int, r: float) -> void:
	var f := frame_of(quad)
	var h := float(floors) * 2.85
	var rows := clampi(int(f.ez * 2.0 / 24.0), 1, 4)
	var per := clampi(int(f.ex * 2.0 / 44.0), 1, 4)
	var pitch_z := f.ez * 1.30 / float(rows)
	for row in rows:
		var z_off := -f.ez * 0.65 + (float(row) + 0.5) * pitch_z
		for k in per:
			var x_off := -f.ex * 0.85 + (float(k) + 0.5) * (f.ex * 1.7 / float(per))
			var q := f.rect(x_off, z_off, f.ex * 0.82 / float(per) * 0.96, minf(pitch_z * 0.36, 7.5), 0.0)
			var rc := tint
			rc.a = 0.0
			var hh := h * (0.85 + GameGlobals.hash2(k, row, 61) * 0.4)
			ctx.buildings.prism(q, GY, hh, rc, 1.0)
			box_collider(ctx, q, GY, hh)
			ctx.emissive.prism(q, GY, GY + 3.2, col(CODE_CONC, Color(0.20, 0.19, 0.21)), 1.015)
			roof_clutter(ctx, q, hh, GameGlobals.hash2(k, row, 62))
		if ctx.detail:
			for k in per * 2:
				var p := f.at((GameGlobals.hash2(k, row, 63) - 0.5) * f.ex * 1.7,
					z_off + f.ez * 0.42)
				tree(ctx, p, 0.8, GameGlobals.hash2(k, row, 64))
	kerb(ctx, quad)


## 弄堂: two rows of narrow 2-3 storey terraces with a shared lane between them.
static func lilong(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color,
		r: float, r3: float) -> void:
	var f := frame_of(quad)
	var h: float = 6.6 + floor(r3 * 3.0) * 2.6
	var depth := clampf(f.ez * 0.34, 3.2, 7.5)
	# Terraces run in depth bands either side of the shared lane, so a deep 弄堂 block is
	# fully built rather than leaving a plaza behind the front row.
	var bands := clampi(int((f.ez * 0.92 - 2.8) / maxf(depth, 1.0)), 1, 4)
	var gap := clampf(f.ez * 0.16, 2.6, 5.5)
	var units := clampi(int(f.ex * 1.8 / 4.4), 3, 22)
	for side in [-1, 1]:
		for band in bands:
			var z_off := float(side) * (gap * 0.5 + depth * (float(band) + 0.5))
			if absf(z_off) > f.ez * 0.96:
				continue
			for u in units:
				var x_off := -f.ex * 0.92 + (float(u) + 0.5) * (f.ex * 1.84 / float(units))
				var q := f.rect(x_off, z_off, f.ex * 0.92 / float(units) * 0.92, depth * 0.5, 0.0)
				var uc := tint
				uc.a = 0.0
				var uh := h * (0.86 + GameGlobals.hash2(u, side + band + 1, 77) * 0.46)
				ctx.buildings.prism(q, GY, uh, uc, 1.0)
				box_collider(ctx, q, GY, uh)
				pitch_roof(ctx, q, uh, 1.3 + GameGlobals.hash2(u, side, 78) * 0.9, f.ax)
	var g := f.at(f.ex * 0.98, 0.0)
	gate(ctx, g, f.ax, 4.2, 4.0)
	kerb(ctx, quad)


## 沿街商业: continuous frontage band with a lit signage strip, yard behind.
static func shopfront(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color,
		r: float, r2: float, intensity: float) -> void:
	var f := frame_of(quad)
	var floors := 2 + int(r2 * 4.0) + (2 if intensity > 0.70 else 0)
	var h := float(floors) * 3.15
	var band := clampf(f.ez * 0.30, 4.0, 9.0)
	var units := clampi(int(f.ex * 1.8 / 7.0), 2, 14)
	for side in [-1, 1]:
		if side > 0 and r2 < 0.38:
			continue
		var z_off := float(side) * (f.ez - band * 0.6) * 0.88
		for u in units:
			var x_off := -f.ex * 0.9 + (float(u) + 0.5) * (f.ex * 1.8 / float(units))
			var q := f.rect(x_off, z_off, f.ex * 0.9 / float(units) * 0.95, band, 0.0)
			var uc := tint
			uc.a = 0.0
			var uh := h * (0.80 + GameGlobals.hash2(u, side + 1, 131) * 0.44)
			ctx.buildings.prism(q, GY, uh, uc, 1.0)
			box_collider(ctx, q, GY, uh)
			if ctx.detail and GameGlobals.hash2(u, side, 132) > 0.74:
				pitch_roof(ctx, q, uh, 1.7, f.ax)
	if ctx.detail:
		var sq := f.rect(0.0, (f.ez - band * 0.6) * 0.88, f.ex * 0.92, band * 0.52, 0.0)
		ctx.emissive.prism(sq, h * 0.78, h * 0.78 + 1.6,
			col(CODE_CONC, [Color(0.88, 0.22, 0.18), Color(0.95, 0.62, 0.10),
				Color(0.12, 0.55, 0.85)][int(r * 3) % 3]), 1.0)
	kerb(ctx, quad)


static func mall(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color, h: float, r: float) -> void:
	var f := frame_of(quad)
	var plot := inset(quad, 4.0)
	var glass := Color(0.32, 0.375, 0.435)
	ctx.buildings.prism(plot, GY, h, glass, 0.98)
	box_collider(ctx, plot, GY, h)
	ctx.buildings.prism(inset(plot, minf(f.ex, f.ez) * 0.18), h, h * 1.42, glass, 0.92)
	box_collider(ctx, inset(plot, minf(f.ex, f.ez) * 0.18), h, h * 1.42)
	if ctx.detail:
		ctx.emissive.prism(inset(plot, minf(f.ex, f.ez) * 0.40), h * 1.42, h * 1.54,
			col(CODE_PLAZA, Color(1.0, 0.72, 0.36)), 1.0)
		var cc := f.at(0.0, f.ez + 3.4)
		var can := f.rect(0.0, f.ez + 3.4, f.ex * 0.52, 2.8, 0.0)
		ctx.props.prism(can, 3.3, 3.9, col(CODE_CONC, Color(0.72, 0.72, 0.74)))
		for s in [-1, 1]:
			var pc := cc + f.ax * f.ex * 0.42 * float(s)
			ctx.props.cylinder(Transform3D(Basis.IDENTITY, Vector3(pc.x, 0.0, pc.y)),
				0.35, 0.32, 3.4, col(CODE_CONC, Color(0.62, 0.62, 0.64)), 8, false)
	kerb(ctx, quad)


# --- Industrial / outer -----------------------------------------------------
static func factory(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color,
		r: float, r2: float, style: String) -> void:
	var f := frame_of(quad)
	var sheds := 1 + int(r * 2.0)
	var span := f.ex * 0.80
	var depth := clampf(f.ez * 0.30, 4.0, 11.0)
	for s in sheds:
		var z_off := (float(s) - float(sheds - 1) * 0.5) * (f.ez * 1.5 / maxf(float(sheds), 1.0))
		var h := 6.0 + GameGlobals.hash2(s, 0, 211) * 9.0
		var q := f.rect(0.0, z_off, span, depth, 0.0)
		var sc := tint
		sc.a = 0.0
		ctx.buildings.prism(q, GY, h, sc, 1.0)
		box_collider(ctx, q, GY, h)
		# Saw-tooth roof: the silhouette of every Chinese industrial hall.
		var teeth := clampi(int(span * 2.0 / 9.0), 2, 10)
		var rc := col(CODE_CONC, Color(0.345, 0.355, 0.385))
		var gl := col(CODE_CONC, Color(0.28, 0.34, 0.40))
		for t in teeth:
			var x0 := -span + (float(t) / float(teeth)) * span * 2.0
			var x1 := -span + (float(t + 1) / float(teeth)) * span * 2.0
			var pa := f.at(x0, z_off - depth)
			var pb := f.at(x1, z_off - depth)
			var pc := f.at(x1, z_off + depth)
			var pd := f.at(x0, z_off + depth)
			ctx.props.quad(Vector3(pa.x, h + 2.3, pa.y), Vector3(pb.x, h + 2.3, pb.y),
				Vector3(pc.x, h + 0.1, pc.y), Vector3(pd.x, h + 0.1, pd.y),
				Vector3(f.az.x, 0.62, f.az.y).normalized(), rc)
			ctx.props.quad(Vector3(pd.x, h + 0.1, pd.y), Vector3(pc.x, h + 0.1, pc.y),
				Vector3(pb.x, h + 2.3, pb.y), Vector3(pa.x, h + 2.3, pa.y),
				Vector3(-f.ax.x, 0.0, -f.ax.y).normalized(), gl)
	if style == "port_industry" or r > 0.45:
		var ch := 28.0 + r2 * 44.0
		var cc := f.at(f.ex * 0.58, f.ez * 0.52)
		var brick := Color(0.55, 0.32, 0.26)
		var xf := Transform3D(Basis.IDENTITY, Vector3(cc.x, 0.0, cc.y))
		ctx.buildings.cylinder(xf, 2.3, 1.35, ch, brick, 10, true)
		ctx.add_box_collider(Vector3(cc.x, ch * 0.5, cc.y), Vector3(5.0, ch, 5.0))
		var band := Color(0.62, 0.60, 0.56)
		for k in 3:
			var s2 := f.at(-f.ex * 0.55 + k * 6.0, f.ez * 0.42)
			ctx.buildings.cylinder(Transform3D(Basis.IDENTITY, Vector3(s2.x, 0.0, s2.y)),
				3.2, 3.2, 13.0 + k * 2.0, band, 12, true)
		if ctx.detail:
			for k in 5:
				var p := f.at((GameGlobals.hash2(k, 1, 212) - 0.5) * f.ex * 1.6,
					(GameGlobals.hash2(k, 2, 213) - 0.5) * f.ez * 1.4)
				ctx.props.box(Transform3D(Basis.IDENTITY.rotated(Vector3.UP,
					(GameGlobals.hash2(k, 3, 214) - 0.5) * 0.6), Vector3(p.x, 0.0, p.y)),
					Vector3(2.4, 2.6, 6.1), col(CODE_CONC,
						[Color(0.72, 0.28, 0.16), Color(0.16, 0.32, 0.62),
							Color(0.20, 0.52, 0.34)][k % 3]))
	kerb(ctx, quad)


static func villas(ctx: ChunkCtx, quad: PackedVector2Array, r: float) -> void:
	var f := frame_of(quad)
	var n := clampi(int(f.area / 900.0), 1, 6)
	for k in n:
		var fx := GameGlobals.hash2(k, 0, 301)
		var fz := GameGlobals.hash2(k, 1, 302)
		var q := f.rect((fx - 0.5) * f.ex * 1.3, (fz - 0.5) * f.ez * 1.25,
			6.0 + fx * 6.0, 5.0 + fz * 5.0, (fz - 0.5) * 0.45)
		var h := 6.2 + fz * 3.8
		var vc := Color(0.73, 0.67, 0.56).lerp(Color(0.56, 0.42, 0.34), fx)
		ctx.buildings.prism(q, GY, h, vc, 1.0)
		box_collider(ctx, q, GY, h)
		hip_roof(ctx, q, h, 2.1 + fz * 1.5, Color(0.34, 0.15, 0.12))
		if ctx.detail:
			var p := f.at((fx - 0.5) * f.ex * 1.3 + 9.0, (fz - 0.5) * f.ez * 1.25)
			tree(ctx, p, 1.0 + fx * 0.6, fx)
	kerb(ctx, quad)


static func parking_lot(ctx: ChunkCtx, quad: PackedVector2Array, r: float) -> void:
	var f := frame_of(quad)
	if r > 0.74:
		var pc := Color(0.55, 0.55, 0.56)
		var h := 16.0 + r * 14.0
		ctx.buildings.prism(inset(quad, 3.0), GY, h, pc, 1.0)
		box_collider(ctx, inset(quad, 3.0), GY, h)
		kerb(ctx, quad)
		return
	for t in int(3 + r * 6.0):
		var p := f.at((GameGlobals.hash2(t, 0, 401) - 0.5) * f.ex * 1.6,
			(GameGlobals.hash2(t, 1, 402) - 0.5) * f.ez * 1.6)
		parked_car(ctx, p, f.ax, GameGlobals.hash2(t, 2, 403))
	for s in 2:
		var lc := f.at((float(s) - 0.5) * f.ex * 1.4, 0.0)
		ctx.props.cylinder(Transform3D(Basis.IDENTITY, Vector3(lc.x, 0.0, lc.y)),
			0.15, 0.13, 8.0, col(CODE_CONC, Color(0.34, 0.35, 0.37)), 6, false)
		ctx.emissive.box(Transform3D(Basis.IDENTITY, Vector3(lc.x, 8.0, lc.y)),
			Vector3(1.4, 0.32, 0.34), Color(1.0, 0.86, 0.6))
	kerb(ctx, quad)


static func park(ctx: ChunkCtx, quad: PackedVector2Array, r: float, r2: float) -> void:
	var f := frame_of(quad)
	var trees := clampi(int(f.area / 340.0), 6, 80)
	for t in trees:
		var a := GameGlobals.hash2(t, 0, 501) * TAU
		var rad := sqrt(GameGlobals.hash2(t, 1, 502)) * 0.9
		var p := f.at(cos(a) * f.ex * rad, sin(a) * f.ez * rad)
		tree(ctx, p, 0.7 + GameGlobals.hash2(t, 2, 503) * 1.0, GameGlobals.hash2(t, 3, 504))
	if r2 > 0.60:
		var pts := PackedVector2Array()
		var n := 14
		for k in n:
			var th := TAU * float(k) / float(n)
			var rr := minf(f.ex, f.ez) * 0.40 * (0.72 + 0.4 * sin(th * 3.0 + r * 6.0))
			pts.append(f.at(cos(th) * rr, sin(th) * rr))
		var mud := col(CODE_MUD, Color(0.27, 0.25, 0.21))
		ctx.plates.polygon_2d(pts, -0.5, mud)
		ctx.plates.skirt(pts, 0.0, 0.06, -0.6, col(CODE_CONC, Color(0.44, 0.43, 0.41)),
			MeshFusion.arc_lengths(pts))
	var pp := PackedVector2Array()
	for k in 9:
		var t := float(k) / 8.0
		pp.append(f.at((t - 0.5) * f.ex * 1.9, (GameGlobals.hash2(k, 7, 505) - 0.5) * f.ez * 1.1))
	ctx.plates.ribbon(pp, 1.7, 0.05, 0.05, col(CODE_PLAZA, Color(0.57, 0.52, 0.44)),
		MeshFusion.arc_lengths(pp))


## Half-finished core inside blue hoarding — a third of every Shanghai district is this.
static func site(ctx: ChunkCtx, quad: PackedVector2Array, tint: Color, h: float, r: float) -> void:
	var f := frame_of(quad)
	var plot := inset(quad, 2.0)
	var hoard := col(CODE_CONC, Color(0.14, 0.28, 0.52))
	ctx.props.skirt(quad, 0.0, 2.3, 0.0, hoard, MeshFusion.arc_lengths(quad), 1)
	ctx.props.skirt(quad, 0.0, 2.3, 0.0, hoard, MeshFusion.arc_lengths(quad), -1)
	var floors := maxi(int(h / 3.1), 2)
	var done := maxi(int(float(floors) * (0.25 + r * 0.5)), 1)
	var core := inset(plot, minf(f.ex, f.ez) * 0.34)
	var grey := Color(0.52, 0.51, 0.49)
	ctx.buildings.prism(core, GY, float(done) * 3.1, grey, 1.0)
	box_collider(ctx, core, GY, float(done) * 3.1)
	if ctx.detail:
		var sc := col(CODE_CONC, Color(0.60, 0.59, 0.57))
		for fl in done:
			ctx.props.prism(core, float(fl) * 3.1 + 0.1, float(fl) * 3.1 + 0.42, sc, 1.05)
		tower_crane(ctx, f.at(f.ex * 0.55, f.ez * 0.45), 42.0 + r * 30.0, r)
	kerb(ctx, quad)


# --- Shared parts -----------------------------------------------------------
static func box_collider(ctx: ChunkCtx, q: PackedVector2Array, y0: float, y1: float) -> void:
	var f := frame_of(q)
	ctx.add_box_collider(Vector3(f.c.x, (y0 + y1) * 0.5, f.c.y),
		Vector3(f.ex * 2.0, maxf(y1 - y0, 1.0), f.ez * 2.0), f.yaw())


static func pitch_roof(ctx: ChunkCtx, q: PackedVector2Array, y: float, rise: float, ax: Vector2) -> void:
	var f := frame_of(q)
	var az := Vector2(-ax.y, ax.x)
	var rc := Color(0.33, 0.155, 0.125)
	for s in [-1, 1]:
		var e0 := f.at(-f.ex, f.ez * float(s))
		var e1 := f.at(f.ex, f.ez * float(s))
		ctx.props.quad(Vector3(e0.x, y + 0.05, e0.y), Vector3(e1.x, y + 0.05, e1.y),
			Vector3(f.c.x + ax.x * f.ex, y + rise, f.c.y + ax.y * f.ex),
			Vector3(f.c.x - ax.x * f.ex, y + rise, f.c.y - ax.y * f.ex),
			Vector3(az.x * float(s), 0.72, az.y * float(s)).normalized(), rc)


static func hip_roof(ctx: ChunkCtx, q: PackedVector2Array, y: float, rise: float, c: Color) -> void:
	var f := frame_of(q)
	var top := inset(q, minf(f.ex, f.ez) * 0.70)
	var n := q.size()
	for i in n:
		var a := q[i]
		var b := q[(i + 1) % n]
		var ta := top[i]
		var tb := top[(i + 1) % n]
		var mid := (a + b) * 0.5 - f.c
		var nrm := Vector3(mid.x, maxf(f.ex, 1.0) * 0.75, mid.y).normalized()
		ctx.props.quad(Vector3(a.x, y, a.y), Vector3(b.x, y, b.y),
			Vector3(tb.x, y + rise, tb.y), Vector3(ta.x, y + rise, ta.y), nrm, c)
	ctx.props.polygon_2d(top, y + rise, c)


static func perimeter_wall(ctx: ChunkCtx, quad: PackedVector2Array, r: float) -> void:
	if not ctx.detail:
		return
	var wc := col(CODE_CONC, Color(0.56, 0.545, 0.52))
	ctx.props.skirt(quad, 0.0, 2.0, 0.0, wc, MeshFusion.arc_lengths(quad), 1)
	ctx.props.skirt(quad, 0.0, 2.0, 0.0, wc, MeshFusion.arc_lengths(quad), -1)
	var f := frame_of(quad)
	gate(ctx, f.at(f.ex * 0.99, 0.0), f.ax, 6.0, 2.6)


static func gate(ctx: ChunkCtx, c: Vector2, ax: Vector2, w: float, h: float) -> void:
	var az := Vector2(-ax.y, ax.x)
	var gc := col(CODE_CONC, Color(0.61, 0.595, 0.56))
	for s in [-1, 1]:
		var p := c + az * (w * 0.5 + 0.7) * float(s)
		ctx.props.box(Transform3D(Basis.IDENTITY, Vector3(p.x, 0.0, p.y)),
			Vector3(1.1, h + 1.7, 1.1), gc)
	ctx.props.box(Transform3D(Basis.IDENTITY, Vector3(c.x, h, c.y)),
		Vector3(w + 2.8, 1.0, 1.5), gc)
	if ctx.detail:
		ctx.emissive.box(Transform3D(Basis.IDENTITY, Vector3(c.x, h + 1.1, c.y)),
			Vector3(w * 0.8, 0.5, 0.95), Color(1.0, 0.78, 0.48))


static func tree(ctx: ChunkCtx, c: Vector2, scale: float, r: float) -> void:
	var s := clampf(scale, 0.45, 2.3)
	ctx.props.cylinder(Transform3D(Basis.IDENTITY, Vector3(c.x, 0.0, c.y)),
		0.17 * s, 0.12 * s, 2.5 * s, col(CODE_GROUND, Color(0.23, 0.165, 0.115)), 5, false)
	var leaf := Color(0.135, 0.255, 0.105) if r < 0.7 else Color(0.245, 0.325, 0.125)
	leaf.a = CODE_GRASS
	var xf := Transform3D(Basis.IDENTITY, Vector3(c.x, 2.2 * s, c.y))
	ctx.props.ellipsoid(xf, Vector3(1.75 * s, 1.55 * s, 1.75 * s), leaf, 4, 6)
	ctx.props.ellipsoid(xf.translated(Vector3(0.75 * s, 0.95 * s, -0.35 * s)),
		Vector3(1.2 * s, 1.0 * s, 1.2 * s), leaf, 4, 6)


static func parked_car(ctx: ChunkCtx, c: Vector2, ax: Vector2, r: float) -> void:
	var body := [Color(0.76, 0.77, 0.79), Color(0.11, 0.11, 0.13), Color(0.34, 0.06, 0.05),
		Color(0.06, 0.13, 0.31), Color(0.50, 0.50, 0.47), Color(0.07, 0.07, 0.08)]
	var bc: Color = body[int(r * 5.99) % 6]
	bc.a = CODE_GROUND
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, atan2(-ax.x, ax.y)),
		Vector3(c.x, 0.42, c.y))
	ctx.props.box(xf, Vector3(1.85, 0.72, 4.4), bc)
	ctx.props.box(xf.translated_local(Vector3(0.0, 0.74, -0.25)),
		Vector3(1.70, 0.62, 2.3), Color(0.05, 0.06, 0.08))


static func tower_crane(ctx: ChunkCtx, c: Vector2, h: float, r: float) -> void:
	var yc := col(CODE_CONC, Color(0.86, 0.62, 0.10))
	var base := Vector3(c.x, 0.0, c.y)
	ctx.props.cylinder(Transform3D(Basis.IDENTITY, base), 0.5, 0.34, h, yc, 6, false)
	var yaw := r * TAU
	var rot := Basis.IDENTITY.rotated(Vector3.UP, yaw)
	var top := base + Vector3(0, h, 0)
	ctx.props.box(Transform3D(rot, top), Vector3(0.7, 0.7, 38.0), yc)
	ctx.props.box(Transform3D(rot, top + rot * Vector3(0, 0, -13.0)),
		Vector3(0.7, 0.7, 13.0), yc)
	ctx.props.box(Transform3D(rot, top + Vector3(0, 3.4, 0)), Vector3(2.5, 2.7, 2.5), yc)
	ctx.props.box(Transform3D(rot, base), Vector3(4.2, 0.6, 4.2), col(CODE_CONC, Color(0.55, 0.55, 0.56)))


static func roof_clutter(ctx: ChunkCtx, q: PackedVector2Array, y: float, r: float) -> void:
	if not ctx.detail:
		return
	var f := frame_of(q)
	var pc := col(CODE_CONC, Color(0.40, 0.395, 0.385))
	ctx.props.skirt(q, 0.0, y + 1.0, y, pc, MeshFusion.arc_lengths(q), 1)
	ctx.props.skirt(q, 0.0, y + 1.0, y, pc, MeshFusion.arc_lengths(q), -1)
	var n := clampi(int(GameGlobals.hash2(int(f.c.x), int(f.c.y), 601) * 4.0), 1, 4)
	for k in n:
		var p := f.at((GameGlobals.hash2(k, 11, 602) - 0.5) * f.ex * 1.3,
			(GameGlobals.hash2(k, 12, 603) - 0.5) * f.ez * 1.3)
		if GameGlobals.hash2(k, 13, 604) > 0.55:
			ctx.props.cylinder(Transform3D(Basis.IDENTITY, Vector3(p.x, y + 0.6, p.y)),
				1.5, 1.5, 2.6, col(CODE_CONC, Color(0.62, 0.63, 0.64)), 8, true)
		else:
			ctx.props.box(Transform3D(Basis.IDENTITY, Vector3(p.x, y + 0.4, p.y)),
				Vector3(2.6 + k * 0.5, 2.2, 2.0), pc)
	if f.ex > 14.0:
		for k in int(2 + r * 5.0):
			var p2 := f.at((GameGlobals.hash2(k, 21, 605) - 0.5) * f.ex * 1.5,
				(GameGlobals.hash2(k, 22, 606) - 0.5) * f.ez * 1.5)
			ctx.props.box(Transform3D(Basis.IDENTITY, Vector3(p2.x, y + 0.5, p2.y)),
				Vector3(1.3, 0.9, 1.9), col(CODE_CONC, Color(0.55, 0.56, 0.58)))
