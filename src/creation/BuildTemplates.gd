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


static func count() -> int:
	return TEMPLATES.size()


static func get_tpl(i: int) -> Dictionary:
	return TEMPLATES[clampi(i, 0, TEMPLATES.size() - 1)]


static func find(id: String) -> Dictionary:
	for t in TEMPLATES:
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
