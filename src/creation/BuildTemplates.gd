class_name BuildTemplates
extends RefCounted
## The catalogue a player builds from.
##
## Every entry reuses the same procedural generators the city itself is built from, so a
## player-placed tower has the same window grid, cornice and night lighting as a generated
## one, and no second renderer or asset pipeline is needed.

const GROUND := 0.02

## kind    which CellProgram generator runs
## size    footprint in metres before the object's own scale
## height  metres, or storey count where the generator works in floors
## style   palette key for Assets.tint_for
const TEMPLATES := [
	{"id": "office_tower", "name": "现代写字楼", "kind": "tower", "size": Vector2(42, 42),
		"height": 128.0, "style": "cbd_tower"},
	{"id": "plinth_tower", "name": "裙房塔楼", "kind": "plinth", "size": Vector2(52, 46),
		"height": 96.0, "style": "modern_mix"},
	{"id": "mall", "name": "购物中心", "kind": "mall", "size": Vector2(78, 54),
		"height": 30.0, "style": "modern_mix"},
	{"id": "xiaoqu", "name": "住宅小区", "kind": "xiaoqu", "size": Vector2(66, 48),
		"height": 18.0, "style": "historic_mix"},
	{"id": "walkup", "name": "老公房", "kind": "walkup", "size": Vector2(58, 34),
		"height": 7.0, "style": "old_industrial"},
	{"id": "lilong", "name": "石库门里弄", "kind": "lilong", "size": Vector2(52, 40),
		"height": 10.0, "style": "historic_mix"},
	{"id": "shopfront", "name": "沿街商业", "kind": "shopfront", "size": Vector2(56, 22),
		"height": 12.0, "style": "diplomatic"},
	{"id": "factory", "name": "工业厂房", "kind": "factory", "size": Vector2(72, 46),
		"height": 16.0, "style": "port_industry"},
	{"id": "villas", "name": "花园别墅", "kind": "villas", "size": Vector2(54, 42),
		"height": 9.0, "style": "suburb"},
	{"id": "parking", "name": "停车楼", "kind": "parking", "size": Vector2(60, 44),
		"height": 14.0, "style": "modern_mix"},
	{"id": "park", "name": "街头绿地", "kind": "park", "size": Vector2(56, 44),
		"height": 0.0, "style": "suburb"},
	{"id": "site", "name": "施工塔吊", "kind": "site", "size": Vector2(46, 38),
		"height": 62.0, "style": "old_industrial"},
]


## 装饰构件 (Phase 127 / 131). These are placed with their true metric size: a two-metre bench
## is a two-metre bench, so the scale control deliberately does not apply to this catalogue —
## a resized chair is not a thing a street needs, and pretending otherwise would make the
## ghost and the built object disagree about what was placed.
##
## kind is "prop" for everything here; prop selects the generator in Props.
const DECOR := [
	{"id": "plane_tree", "name": "悬铃木", "kind": "prop", "prop": "plane_tree",
		"size": Vector2(5, 5), "height": 0.0, "style": "suburb", "cat": "decor"},
	{"id": "bench", "name": "长椅", "kind": "prop", "prop": "bench",
		"size": Vector2(1.8, 0.9), "height": 0.0, "style": "suburb", "cat": "decor"},
	{"id": "litter_bin", "name": "垃圾桶", "kind": "prop", "prop": "litter_bin",
		"size": Vector2(0.8, 0.8), "height": 0.0, "style": "suburb", "cat": "decor"},
	{"id": "bollard", "name": "隔离桩", "kind": "prop", "prop": "bollard",
		"size": Vector2(0.4, 0.4), "height": 0.0, "style": "suburb", "cat": "decor"},
	{"id": "street_lamp", "name": "路灯", "kind": "prop", "prop": "street_lamp",
		"size": Vector2(1.8, 0.6), "height": 0.0, "style": "suburb", "cat": "decor"},
	{"id": "stop_sign", "name": "公交站牌", "kind": "prop", "prop": "stop_sign",
		"size": Vector2(1.4, 0.6), "height": 0.0, "style": "suburb", "cat": "decor"},
	{"id": "ad_board", "name": "广告灯箱", "kind": "prop", "prop": "ad_board",
		"size": Vector2(2.6, 0.6), "height": 0.0, "style": "cbd_tower", "cat": "decor"},
	{"id": "barrier", "name": "施工水马", "kind": "prop", "prop": "barrier",
		"size": Vector2(2.0, 0.5), "height": 0.0, "style": "old_industrial", "cat": "decor"},
	{"id": "curb_car", "name": "路边停车", "kind": "prop", "prop": "parked_car",
		"size": Vector2(2.0, 4.6), "height": 0.0, "style": "suburb", "cat": "decor"},
]


static func count() -> int:
	return TEMPLATES.size()


## The palette a tool shows. Buildings and props are separate lists because cycling through
## twelve towers to reach a bench is not an interface, and because the zone size cap only makes
## sense when the catalogue itself is scoped. Takes a plain bool rather than the Tool enum to
## avoid a CreationSystem <-> BuildTemplates type cycle.
static func palette(decor: bool) -> Array:
	return DECOR if decor else TEMPLATES


static func get_at(list: Array, i: int) -> Dictionary:
	if list.is_empty():
		return TEMPLATES[0]
	return list[clampi(i, 0, list.size() - 1)]


static func get_tpl(i: int) -> Dictionary:
	return TEMPLATES[clampi(i, 0, TEMPLATES.size() - 1)]


static func find(id: String) -> Dictionary:
	for t in TEMPLATES:
		if String(t["id"]) == id:
			return t
	for t in DECOR:
		if String(t["id"]) == id:
			return t
	return TEMPLATES[0]


## A rectangle centred on c, rotated by yaw, in the same world XZ space the generators use.
static func rect(c: Vector2, size: Vector2, yaw: float) -> PackedVector2Array:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var cth := cos(yaw)
	var sth := sin(yaw)
	var out := PackedVector2Array()
	for p in [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)]:
		out.append(c + Vector2(p.x * cth - p.y * sth, p.x * sth + p.y * cth))
	return out


## GDScript has no fract(); the generators want a second, independent 0..1 value per object
## and deriving it here keeps that out of every call site.
static func _frac(x: float) -> float:
	return x - floor(x)


## Emit one object into ctx. r is a stable per-object random so a given placement keeps the
## same window pattern and tint after a save/reload cycle.
static func build(ctx: ChunkCtx, tpl: Dictionary, quad: PackedVector2Array, r: float) -> void:
	var style := String(tpl["style"])
	var tint := Assets.tint_for(style, r)
	var h := float(tpl["height"])
	match String(tpl["kind"]):
		"prop":
			# Props are emitted around the node origin; the object's own yaw and position come
			# from the node transform, so a bench rotates by editing one transform like anything
			# else in the editor.
			_prop(ctx, String(tpl["prop"]), r)
		"tower":
			CellProgram.tower(ctx, quad, tint, h, r)
		"plinth":
			CellProgram.plinth_tower(ctx, quad, tint, h, r)
		"mall":
			CellProgram.mall(ctx, quad, tint, h, r)
		"xiaoqu":
			CellProgram.xiaoqu(ctx, quad, tint, maxi(4, int(h / 3.0)), r)
		"walkup":
			CellProgram.walkup_rows(ctx, quad, tint, clampi(int(h / 3.0), 3, 9), r)
		"lilong":
			CellProgram.lilong(ctx, quad, tint, r, _frac(r * 7.13))
		"shopfront":
			CellProgram.shopfront(ctx, quad, tint, r, _frac(r * 3.77), 0.6)
		"factory":
			CellProgram.factory(ctx, quad, tint, r, _frac(r * 5.31), style)
		"villas":
			CellProgram.villas(ctx, quad, r)
		"parking":
			CellProgram.parking_lot(ctx, quad, r)
		"park":
			CellProgram.park(ctx, quad, r, _frac(r * 2.19))
		"site":
			CellProgram.site(ctx, quad, tint, h, r)
		_:
			CellProgram.tower(ctx, quad, tint, h, r)


# --- Player-built road ------------------------------------------------------
static func _prop(ctx: ChunkCtx, name: String, r: float) -> void:
	match name:
		"plane_tree":
			Props.plane_tree(ctx, Vector2.ZERO, r)
		"bench":
			Props.bench(ctx, Vector2.ZERO, 0.0, r)
		"litter_bin":
			Props.litter_bin(ctx, Vector2.ZERO, 0.0, r)
		"bollard":
			Props.bollard(ctx, Vector2.ZERO, 0.0, r)
		"street_lamp":
			Props.street_lamp(ctx, Vector2.ZERO, 0.0, r)
		"stop_sign":
			Props.stop_sign(ctx, Vector2.ZERO, 0.0, r)
		"ad_board":
			Props.ad_board(ctx, Vector2.ZERO, 0.0, r)
		"barrier":
			Props.barrier(ctx, Vector2.ZERO, 0.0, r)
		"parked_car":
			Props.parked_car(ctx, Vector2.ZERO, 0.0, r)
		_:
			Props.bollard(ctx, Vector2.ZERO, 0.0, r)


## A straight segment with carriageway, centre dashes, kerbed sidewalks and street lamps,
## assembled from the same MeshFusion primitives the avenue builder uses.
static func build_road(ctx: ChunkCtx, a: Vector2, b: Vector2, w: float) -> void:
	var pts := PackedVector2Array([a, b])
	var arcs := MeshFusion.arc_lengths(pts)
	var dir := (b - a).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	var asphalt := Color(0.0, 0.0, 0.0)
	asphalt.a = CellProgram.CODE_GROUND
	ctx.streets.ribbon(pts, w * 0.5, 0.06, 0.06, asphalt, arcs)

	var white := Color(0.78, 0.77, 0.72)
	white.a = CellProgram.CODE_GROUND
	var l := a.distance_to(b)
	var n := int(l / 9.0)
	for k in n:
		if k % 2 == 1:
			continue
		var seg := PackedVector2Array([
			a + dir * (float(k) / float(n) * l),
			a + dir * ((float(k) + 0.62) / float(n) * l)])
		ctx.streets.ribbon(seg, 0.09, 0.075, 0.075, white, MeshFusion.arc_lengths(seg))

	var pave := Color(0.42, 0.41, 0.40)
	pave.a = CellProgram.CODE_PAVE
	var kerb := Color(0.52, 0.51, 0.50)
	kerb.a = CellProgram.CODE_CONC
	for side_v in [-1.0, 1.0]:
		var side: float = side_v
		var off: Vector2 = nrm * (w * 0.5 + 1.7) * side
		ctx.plates.ribbon(PackedVector2Array([a + off, b + off]), 1.7, 0.05, 0.05,
			pave, arcs)
		var edge: Vector2 = nrm * (w * 0.5 + 0.15) * side
		ctx.props.skirt(PackedVector2Array([a + edge, b + edge]), 0.15, 0.16, 0.0,
			kerb, arcs, int(side))

	var steel := Color(0.30, 0.31, 0.33)
	steel.a = CellProgram.CODE_CONC
	var lamps := clampi(int(l / 34.0), 1, 40)
	for k in lamps:
		var t := (float(k) + 0.5) / float(lamps)
		var side := 1.0 if k % 2 == 0 else -1.0
		var p := a.lerp(b, t) + nrm * (w * 0.5 + 3.2) * side
		var xf := Transform3D(Basis.IDENTITY, Vector3(p.x, 0.0, p.y))
		ctx.props.cylinder(xf, 0.16, 0.10, 8.4, steel, 6, false)
		var arm := nrm * 1.5 * side
		var mid := Vector3(p.x + arm.x * 0.5, 8.2, p.y + arm.y * 0.5)
		ctx.props.box(Transform3D(Basis.IDENTITY, mid),
			Vector3(absf(arm.x) + 0.25, 0.16, absf(arm.y) + 0.25), steel)
		ctx.emissive.box(Transform3D(Basis.IDENTITY, Vector3(p.x + arm.x, 7.85, p.y + arm.y)),
			Vector3(0.95, 0.30, 0.42), Color(1.0, 0.84, 0.60))
