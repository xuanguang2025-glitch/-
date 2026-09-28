extends Node
## Shanghai spatial model.
##
## Origin = People's Square, 1 unit = 1 metre, +X = east, +Z = south (north is -Z).
## Offsets are calibrated to the real city so ring-road / river / district relationships
## read correctly: The Bund ~1.3 km east of People's Square, Lujiazui directly across the
## water, Oriental Pearl ~2.5 km NE, Jing'an Temple ~2.4 km west, Xujiahui ~3 km SW.
##
## River control points are Vector3(x, northing_z, half_width) — note .y holds the map-Z
## coordinate and .z holds the channel half-width.
##
## All generation reads through the pure query functions at the bottom, so the same data
## drives meshes, traffic spawners, the minimap and collision without divergence.

# --- Water ------------------------------------------------------------------
const HUANGPU_RAW := [
	Vector3(-3200.0, 8600.0, 190.0),
	Vector3(-1300.0, 7300.0, 200.0),
	Vector3(300.0, 6100.0, 210.0),
	Vector3(780.0, 5000.0, 215.0),
	Vector3(1050.0, 4050.0, 220.0),	# 卢浦大桥
	Vector3(1260.0, 3150.0, 222.0),
	Vector3(1420.0, 2300.0, 224.0),	# 南浦大桥
	Vector3(1500.0, 1500.0, 226.0),	# 董家渡 / 南外滩
	Vector3(1530.0, 600.0, 228.0),	# 外滩核心（西岸 x≈1300）
	Vector3(1585.0, -250.0, 230.0),	# 南京东路口
	Vector3(1700.0, -1000.0, 232.0),	# 外白渡桥 / 苏州河口
	Vector3(2050.0, -1550.0, 235.0),	# 北外滩，开始东折
	Vector3(2750.0, -1900.0, 240.0),
	Vector3(3400.0, -2000.0, 245.0),	# 陆家嘴大弯顶点
	Vector3(3900.0, -2450.0, 248.0),
	Vector3(4000.0, -3200.0, 250.0),	# 定海桥
	Vector3(3750.0, -4100.0, 255.0),	# 杨浦大桥
	Vector3(3300.0, -5000.0, 258.0),
	Vector3(3050.0, -6100.0, 262.0),	# 复兴岛
	Vector3(2950.0, -7500.0, 265.0),
	Vector3(3000.0, -9200.0, 270.0),
]

const SUZHOU_CREEK_RAW := [
	Vector3(1700.0, -1000.0, 32.0),
	Vector3(1000.0, -1150.0, 30.0),
	Vector3(250.0, -1080.0, 29.0),
	Vector3(-600.0, -1250.0, 28.0),
	Vector3(-1500.0, -1180.0, 27.0),
	Vector3(-2350.0, -1450.0, 26.0),	# 曹家渡 / 中山公园
	Vector3(-3200.0, -1350.0, 26.0),
	Vector3(-4100.0, -1600.0, 25.0),
	Vector3(-5200.0, -1500.0, 24.0),
	Vector3(-6600.0, -1700.0, 24.0),
]

# --- Ring roads -------------------------------------------------------------
const RINGS := [
	{"rx": 2350.0, "rz": 2150.0, "width": 24.0, "elevated": false, "name": "内环高架", "lanes": 4},
	{"rx": 4250.0, "rz": 4000.0, "width": 28.0, "elevated": true, "name": "中环路", "lanes": 6},
	{"rx": 5950.0, "rz": 5700.0, "width": 32.0, "elevated": true, "name": "外环线", "lanes": 8},
]

# --- Named arterial spines --------------------------------------------------
const ARTERIES := [
	{"name": "南京东路—南京西路", "width": 26.0, "lanes": 4, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(-4600, -430), Vector2(-2600, -430), Vector2(-1200, -400),
			Vector2(0, -360), Vector2(700, -380), Vector2(1270, -350)]},
	{"name": "延安高架路", "width": 24.0, "lanes": 4, "elevated": true, "deck_y": 9.5,
		"path": [Vector2(-5200, 700), Vector2(-3000, 690), Vector2(-1300, 640),
			Vector2(0, 620), Vector2(900, 500), Vector2(1500, 380),
			Vector2(2350, 260), Vector2(3350, 300)]},
	{"name": "淮海中路", "width": 18.0, "lanes": 3, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(-3300, 1500), Vector2(-1600, 1350), Vector2(-200, 1150),
			Vector2(600, 1050), Vector2(1400, 950), Vector2(2100, 800)]},
	{"name": "世纪大道", "width": 44.0, "lanes": 8, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(2150, -250), Vector2(2900, 450), Vector2(3650, 1200),
			Vector2(4400, 2000), Vector2(5000, 2800)]},
	{"name": "浦东大道", "width": 22.0, "lanes": 4, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(1900, -1450), Vector2(2900, -1600), Vector2(4000, -1700), Vector2(5400, -1800)]},
	{"name": "龙阳路高架", "width": 26.0, "lanes": 5, "elevated": true, "deck_y": 10.5,
		"path": [Vector2(3300, 1500), Vector2(4100, 1350), Vector2(5000, 1200), Vector2(5900, 1100)]},
	{"name": "沪闵路", "width": 22.0, "lanes": 4, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(-1100, 2500), Vector2(-1500, 3600), Vector2(-1900, 4800), Vector2(-2200, 6100)]},
	{"name": "共和新路", "width": 22.0, "lanes": 4, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(-500, -1900), Vector2(-400, -3000), Vector2(-250, -4200), Vector2(-100, -5800)]},
	{"name": "曹安公路", "width": 24.0, "lanes": 4, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(-2500, -1900), Vector2(-3600, -2350), Vector2(-4900, -2800), Vector2(-6100, -3300)]},
	{"name": "沪太路", "width": 20.0, "lanes": 3, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(-1900, -2300), Vector2(-2300, -3600), Vector2(-2700, -5200)]},
	{"name": "龙华西路", "width": 18.0, "lanes": 3, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(-1900, 1500), Vector2(-2200, 2600), Vector2(-2500, 4000)]},
	{"name": "张杨路", "width": 20.0, "lanes": 4, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(2400, -700), Vector2(3200, -500), Vector2(4200, -200), Vector2(5400, 100)]},
	{"name": "南北高架路", "width": 22.0, "lanes": 4, "elevated": true, "deck_y": 10.0,
		"path": [Vector2(-150, -4300), Vector2(-120, -2200), Vector2(0, -400), Vector2(180, 1400), Vector2(320, 2600)]},
	{"name": "中山东一路(外滩)", "width": 16.0, "lanes": 3, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(1290, -900), Vector2(1320, 0), Vector2(1360, 900), Vector2(1420, 2100)]},
	{"name": "逸仙高架路", "width": 20.0, "lanes": 4, "elevated": true, "deck_y": 9.0,
		"path": [Vector2(2500, -2300), Vector2(2700, -3600), Vector2(2900, -5200)]},
	{"name": "军工路", "width": 18.0, "lanes": 3, "elevated": false, "deck_y": 0.0,
		"path": [Vector2(3400, -4600), Vector2(3200, -5800), Vector2(3000, -7000)]},
]

# --- Districts --------------------------------------------------------------
const DISTRICTS := [
	{"name": "黄浦区", "cx": 600.0, "cz": 700.0, "r": 2000.0, "style": "historic_mix",
		"density": 0.95, "hmin": 14.0, "hmax": 78.0, "grid": 0.62, "block": 108.0},
	{"name": "陆家嘴", "cx": 2750.0, "cz": 150.0, "r": 1500.0, "style": "cbd_tower",
		"density": 0.90, "hmin": 70.0, "hmax": 430.0, "grid": 0.10, "block": 170.0},
	{"name": "静安区", "cx": -1500.0, "cz": -900.0, "r": 2100.0, "style": "modern_mix",
		"density": 0.88, "hmin": 22.0, "hmax": 130.0, "grid": 0.16, "block": 118.0},
	{"name": "普陀区", "cx": -3300.0, "cz": -1100.0, "r": 1900.0, "style": "old_industrial",
		"density": 0.72, "hmin": 12.0, "hmax": 54.0, "grid": 0.30, "block": 132.0},
	{"name": "虹口区", "cx": 900.0, "cz": -2600.0, "r": 1800.0, "style": "historic_mix",
		"density": 0.82, "hmin": 16.0, "hmax": 72.0, "grid": 0.44, "block": 112.0},
	{"name": "杨浦区", "cx": 2900.0, "cz": -3900.0, "r": 2100.0, "style": "campus_industrial",
		"density": 0.70, "hmin": 14.0, "hmax": 88.0, "grid": 0.22, "block": 140.0},
	{"name": "长宁区", "cx": -2900.0, "cz": 800.0, "r": 1900.0, "style": "diplomatic",
		"density": 0.68, "hmin": 18.0, "hmax": 108.0, "grid": 0.05, "block": 126.0},
	{"name": "徐汇区", "cx": -900.0, "cz": 3000.0, "r": 2100.0, "style": "modern_mix",
		"density": 0.80, "hmin": 20.0, "hmax": 120.0, "grid": 0.50, "block": 120.0},
	{"name": "浦东新区", "cx": 4600.0, "cz": 1800.0, "r": 3000.0, "style": "sprawl_tower",
		"density": 0.60, "hmin": 24.0, "hmax": 112.0, "grid": 0.00, "block": 155.0},
	{"name": "闵行区", "cx": -2400.0, "cz": 4900.0, "r": 2300.0, "style": "suburb",
		"density": 0.50, "hmin": 12.0, "hmax": 46.0, "grid": 0.00, "block": 150.0},
	{"name": "宝山区", "cx": -600.0, "cz": -5400.0, "r": 2400.0, "style": "port_industry",
		"density": 0.42, "hmin": 10.0, "hmax": 40.0, "grid": 0.12, "block": 180.0},
]
const RURAL := {"name": "郊区", "cx": 0.0, "cz": 0.0, "r": 1200.0, "style": "rural",
	"density": 0.30, "hmin": 6.0, "hmax": 24.0, "grid": 0.0, "block": 200.0}

# --- Landmarks --------------------------------------------------------------
## type maps to a factory in LandmarkFactory. Original massing inspired by the real
## structure — no licensed geometry.
const LANDMARKS := [
	{"type": "pearl_tower", "name": "东方明珠", "x": 2180.0, "z": -1180.0, "rot": 0.20, "clear": 175.0},
	{"type": "shanghai_tower", "name": "上海中心大厦", "x": 2690.0, "z": -640.0, "rot": 0.0, "clear": 140.0},
	{"type": "swfc", "name": "上海环球金融中心", "x": 2530.0, "z": -800.0, "rot": 0.06, "clear": 130.0},
	{"type": "jinmao", "name": "金茂大厦", "x": 2400.0, "z": -1000.0, "rot": 0.12, "clear": 130.0},
	{"type": "icbc_tower", "name": "工行大厦", "x": 2900.0, "z": -350.0, "rot": 0.0, "clear": 110.0},
	{"type": "bund_row", "name": "外滩万国建筑群", "x": 1290.0, "z": -150.0, "rot": 1.53, "len": 1500.0, "clear": 80.0},
	{"type": "peace_hotel", "name": "和平饭店", "x": 1272.0, "z": -330.0, "rot": 1.53, "clear": 70.0},
	{"type": "customs_house", "name": "海关大楼", "x": 1288.0, "z": -40.0, "rot": 1.53, "clear": 70.0},
	{"type": "bank_of_china", "name": "中国银行大楼", "x": 1304.0, "z": 220.0, "rot": 1.53, "clear": 70.0},
	{"type": "municipal_hall", "name": "上海市政府", "x": 3350.0, "z": 900.0, "rot": 0.0, "clear": 150.0},
	{"type": "museum", "name": "上海博物馆", "x": -60.0, "z": 200.0, "rot": 0.0, "clear": 130.0},
	{"type": "grand_theatre", "name": "上海大剧院", "x": -300.0, "z": -200.0, "rot": 0.0, "clear": 120.0},
	{"type": "plaza", "name": "人民广场", "x": 0.0, "z": 0.0, "rot": 0.0, "r": 330.0, "clear": 300.0},
	{"type": "yuyuan", "name": "豫园·城隍庙", "x": 760.0, "z": 1780.0, "rot": 0.15, "clear": 260.0},
	{"type": "xintiandi", "name": "新天地", "x": 480.0, "z": 1080.0, "rot": 0.45, "clear": 180.0},
	{"type": "jingan_temple", "name": "静安寺", "x": -2380.0, "z": -520.0, "rot": 0.0, "clear": 130.0},
	{"type": "stadium", "name": "上海体育场", "x": -1950.0, "z": 3350.0, "rot": 0.0, "r": 190.0, "clear": 250.0},
	{"type": "cathedral", "name": "徐家汇天主教堂", "x": -1180.0, "z": 2720.0, "rot": 0.10, "clear": 110.0},
	{"type": "wujiaochang", "name": "五角场", "x": 2780.0, "z": -4050.0, "rot": 0.0, "r": 260.0, "clear": 240.0},
	{"type": "railway_station", "name": "上海火车站", "x": -350.0, "z": -2550.0, "rot": 0.0, "clear": 190.0},
	{"type": "hongqiao_hub", "name": "虹桥综合枢纽", "x": -5350.0, "z": -250.0, "rot": 0.0, "clear": 520.0},
	{"type": "disney_castle", "name": "迪士尼乐园", "x": 5150.0, "z": 4300.0, "rot": 0.0, "clear": 420.0},
	{"type": "pudong_airport", "name": "浦东国际机场", "x": 5700.0, "z": 3050.0, "rot": -0.35, "clear": 850.0},
]

# --- Parks / protected open ground ------------------------------------------
const PARKS := [
	{"name": "复兴公园", "x": 620.0, "z": 620.0, "r": 210.0},
	{"name": "静安公园", "x": -1680.0, "z": -600.0, "r": 170.0},
	{"name": "太平桥绿地", "x": 380.0, "z": 1350.0, "r": 190.0},
	{"name": "世纪公园", "x": 4350.0, "z": 1250.0, "r": 620.0},
	{"name": "共青森林公园", "x": 2450.0, "z": -6100.0, "r": 700.0},
	{"name": "大宁公园", "x": -100.0, "z": -4100.0, "r": 330.0},
	{"name": "黄兴公园", "x": 2500.0, "z": -3200.0, "r": 280.0},
	{"name": "徐汇滨江绿地", "x": -250.0, "z": 4300.0, "r": 400.0},
	{"name": "前滩", "x": 2350.0, "z": 3150.0, "r": 480.0},
	{"name": "桂林公园", "x": -3300.0, "z": 2200.0, "r": 190.0},
	{"name": "鲁迅公园", "x": 300.0, "z": -2600.0, "r": 200.0},
	{"name": "大唐公园", "x": 3900.0, "z": -1200.0, "r": 240.0},
]

# --- Runtime caches ---------------------------------------------------------
var huangpu_xz: PackedVector2Array
var huangpu_hw: PackedFloat32Array
var creek_xz: PackedVector2Array
var creek_hw: PackedFloat32Array
var _seg_a: PackedVector2Array
var _seg_b: PackedVector2Array
var _seg_w: PackedFloat32Array
var _seg_kind: PackedInt32Array
var _seg_grid: Dictionary = {}
var _water_near: Dictionary = {}
const _SEARCH := 4
var _cell := 250.0
var _water_half_max := 280.0
var landmark_cells: Dictionary = {}

## Road polylines expanded into a queryable form (rings sampled, arteries densified).
var roads: Array = []


func _ready() -> void:
	_init_grids()
	_build_offsets()
	huangpu_xz = PackedVector2Array()
	huangpu_hw = PackedFloat32Array()
	creek_xz = PackedVector2Array()
	creek_hw = PackedFloat32Array()
	_densify(HUANGPU_RAW, huangpu_xz, huangpu_hw, 16)
	_densify(SUZHOU_CREEK_RAW, creek_xz, creek_hw, 6)
	_index_water(huangpu_xz, huangpu_hw, 0)
	_index_water(creek_xz, creek_hw, 1)
	_mark_water_near()
	_build_roads()
	_index_roads()
	_index_landmarks()


func _densify(raw: Array, out_xz: PackedVector2Array, out_w: PackedFloat32Array, steps: int) -> void:
	for i in range(raw.size() - 1):
		var p0: Vector3 = raw[maxi(i - 1, 0)]
		var p1: Vector3 = raw[i]
		var p2: Vector3 = raw[i + 1]
		var p3: Vector3 = raw[mini(i + 2, raw.size() - 1)]
		for s in steps:
			var t := float(s) / float(steps)
			out_xz.append(_catmull_xz(p0, p1, p2, p3, t))
			out_w.append(lerpf(p1.z, p2.z, t))
	out_xz.append(Vector2(raw[raw.size() - 1].x, raw[raw.size() - 1].y))
	out_w.append(raw[raw.size() - 1].z)


func _catmull_xz(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	var xf := 0.5 * ((2.0 * p1.x) + (-p0.x + p2.x) * t
		+ (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2
		+ (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3)
	var zf := 0.5 * ((2.0 * p1.y) + (-p0.y + p2.y) * t
		+ (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2
		+ (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3)
	return Vector2(xf, zf)


func _index_water(poly: PackedVector2Array, widths: PackedFloat32Array, kind: int) -> void:
	for i in range(poly.size() - 1):
		var idx := _seg_a.size()
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[i + 1]
		var w: float = maxf(widths[i], widths[i + 1])
		_water_half_max = maxf(_water_half_max, w)
		_seg_a.append(a)
		_seg_b.append(b)
		_seg_w.append(w)
		_seg_kind.append(kind)
		var c0 := Vector2i(int(floor(a.x / _cell)), int(floor(a.y / _cell)))
		var c1 := Vector2i(int(floor(b.x / _cell)), int(floor(b.y / _cell)))
		for cx in range(mini(c0.x, c1.x) - 1, maxi(c0.x, c1.x) + 2):
			for cz in range(mini(c0.y, c1.y) - 1, maxi(c0.y, c1.y) + 2):
				var key := Vector2i(cx, cz)
				if not _seg_grid.has(key):
					_seg_grid[key] = []
				(_seg_grid[key] as Array).append(idx)


## Index of the water segment nearest to p, or -1. Typed-array scan: the earlier
## Dictionary-of-segments form cost three string lookups per candidate, and every ground
## sample walks hundreds of candidates.
func _mark_water_near() -> void:
	_water_near.clear()
	for key in _seg_grid.keys():
		var c: Vector2i = key
		for ox in range(-_SEARCH, _SEARCH + 1):
			for oz in range(-_SEARCH, _SEARCH + 1):
				_water_near[c + Vector2i(ox, oz)] = true


## Bucket offsets ordered by ring distance, with a suffix-minimum of the closest any bucket
## at or after that position can be to the query point. Nearest-neighbour searches walk this
## order so the first real hit tightens the bound, then the tail is dropped in one test.
var _off: Array[Vector2i] = []
var _off_lb: PackedFloat32Array	## in bucket units; multiply by the index's cell size


func _build_offsets() -> void:
	var pairs: Array = []
	for ox in range(-_SEARCH, _SEARCH + 1):
		for oz in range(-_SEARCH, _SEARCH + 1):
			pairs.append([Vector2i(ox, oz), sqrt(float(ox * ox + oz * oz))])
	pairs.sort_custom(func(a, b): return a[1] < b[1])
	_off.clear()
	for pr in pairs:
		_off.append(pr[0])
	_off_lb.resize(_off.size() + 1)
	_off_lb[_off.size()] = 1e9
	for k in range(_off.size() - 1, -1, -1):
		var o := _off[k]
		var lx := maxf(float(absi(o.x) - 1), 0.0)
		var lz := maxf(float(absi(o.y) - 1), 0.0)
		_off_lb[k] = minf(sqrt(lx * lx + lz * lz), _off_lb[k + 1])


## Signed distance to the nearest waterline; negative means under water.
##
## A cell whose whole search window is empty cannot hold a candidate, and there the true
## distance is beyond every threshold callers test, so the answer is immediate. Without this
## shortcut each of the ~100 ground samples per chunk walked 81 buckets looking for nothing.
func _water_dist(p: Vector2) -> float:
	var cx := int(floor(p.x / _cell))
	var cz := int(floor(p.y / _cell))
	if not _water_near.has(Vector2i(cx, cz)):
		return 1e9
	var best := 1e9
	for k in _off.size():
		if _off_lb[k] * _cell - _water_half_max >= best:
			break
		var o := _off[k]
		var key := Vector2i(cx + o.x, cz + o.y)
		if not _seg_grid.has(key):
			continue
		var bx := float(key.x) * _cell
		var dx := maxf(maxf(bx - p.x, p.x - (bx + _cell)), 0.0)
		var bz := float(key.y) * _cell
		var dz := maxf(maxf(bz - p.y, p.y - (bz + _cell)), 0.0)
		if sqrt(dx * dx + dz * dz) - _water_half_max >= best:
			continue
		for idx_v in (_seg_grid[key] as Array):
			var a: Vector2 = _seg_a[idx_v]
			var ab: Vector2 = _seg_b[idx_v] - a
			var len2 := ab.length_squared()
			var t := 0.0 if len2 < 0.0001 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t) - _seg_w[idx_v]
			if d < best:
				best = d
	return best


func _build_roads() -> void:
	roads.clear()
	for ring in RINGS:
		var pts := PackedVector2Array()
		var n := 256
		for i in n + 1:
			var th := TAU * float(i) / float(n)
			pts.append(Vector2(cos(th) * ring["rx"], sin(th) * ring["rz"]))
		roads.append({"name": ring["name"], "path": pts, "width": ring["width"],
			"lanes": ring["lanes"], "elevated": ring["elevated"], "deck_y": 11.0 if ring["elevated"] else 0.0,
			"kind": "ring"})
	for a in ARTERIES:
		roads.append({"name": a["name"], "path": PackedVector2Array(a["path"]),
			"width": a["width"], "lanes": a["lanes"], "elevated": a["elevated"],
			"deck_y": a["deck_y"], "kind": "artery"})


func _index_landmarks() -> void:
	landmark_cells.clear()
	for lm in LANDMARKS:
		var c := chunk_of(Vector2(lm["x"], lm["z"]))
		if not landmark_cells.has(c):
			landmark_cells[c] = []
		(landmark_cells[c] as Array).append(lm)
		# Large footprints bleed into neighbouring chunks.
		if landmark_footprint(lm) > GameGlobals.CHUNK_SIZE * 0.5:
			for ox in range(-3, 4):
				for oz in range(-3, 4):
					var k := c + Vector2i(ox, oz)
					if not landmark_cells.has(k):
						landmark_cells[k] = []
					if not (landmark_cells[k] as Array).has(lm):
						(landmark_cells[k] as Array).append(lm)


static func chunk_of(p: Vector2) -> Vector2i:
	var s := GameGlobals.CHUNK_SIZE
	return Vector2i(int(floor(p.x / s)), int(floor(p.y / s)))


func world_to_chunk(p: Vector2) -> Vector2i:
	return chunk_of(p)


func chunk_center(c: Vector2i) -> Vector2:
	var s := GameGlobals.CHUNK_SIZE
	return Vector2(c.x * s, c.y * s)


func in_bounds(c: Vector2i) -> bool:
	var half := int(GameGlobals.WORLD_HALF / GameGlobals.CHUNK_SIZE)
	return absi(c.x) <= half and absi(c.y) <= half


# --- Water queries ----------------------------------------------------------
## Point-accurate on purpose: the avatar, the bridge/tunnel decision along each avenue and
## the spawn search all ask "am I in the river", and a 25 m quantised answer can drop them
## into the channel. Bulk generation asks water_dist_q instead.
func in_water(p: Vector2) -> bool:
	return _water_dist(p) < 0.0


## Terrain height of the streamed ground mesh at p. The ground grid is built from this same
## function, so anything placed into the world (a player, a built object) rests on it.
const BANK_Y := -13.0
const BANK_FALLOFF := 14.0


func terrain_y(p: Vector2) -> float:
	var d: float = water_dist_q(p)
	if d >= BANK_FALLOFF:
		return 0.0
	if d <= 0.0:
		return BANK_Y
	return lerpf(BANK_Y, 0.0, pow(d / BANK_FALLOFF, 0.62))


## Exact signed distance, for callers that must clear the bank by a stated margin.
func water_dist_exact(p: Vector2) -> float:
	return _water_dist(p)


# --- Query memo -------------------------------------------------------------
## Generating one chunk used to ask the same three questions (how far from water, how far
## from an avenue, how urban is here) thousands of times through overlapping call paths,
## which cost ~98 ms per chunk. These quantised grids collapse that to one scan per cell.
##
## Deliberately fixed-size arrays rather than Dictionaries: a Dictionary that has to be
## cleared when it grows past a cap turns the whole map into a repeated cold-cache walk.
const Q_STEP := 25.0
const Q_PAD := 900.0

var _qn := 0
var _qext := 0.0
var _g_water: PackedFloat32Array
var _g_water_set: PackedByteArray
var _g_major: PackedFloat32Array
var _g_major_set: PackedByteArray
var _g_inten: PackedFloat32Array
var _g_inten_set: PackedByteArray
var _g_park: PackedFloat32Array
var _g_park_set: PackedByteArray
var _q_district: Dictionary = {}
var memo_hits: int = 0
var memo_miss: int = 0


func _init_grids() -> void:
	_qext = GameGlobals.WORLD_HALF + Q_PAD
	_qn = int(ceil(_qext * 2.0 / Q_STEP))
	var cells := _qn * _qn
	_g_water.resize(cells)
	_g_major.resize(cells)
	_g_inten.resize(cells)
	_g_park.resize(cells)
	_g_water_set.resize(cells)
	_g_major_set.resize(cells)
	_g_inten_set.resize(cells)
	_g_park_set.resize(cells)
	_g_water_set.fill(0)
	_g_major_set.fill(0)
	_g_inten_set.fill(0)
	_g_park_set.fill(0)


func _gidx(p: Vector2) -> int:
	var cx := clampi(int((p.x + _qext) / Q_STEP), 0, _qn - 1)
	var cz := clampi(int((p.y + _qext) / Q_STEP), 0, _qn - 1)
	return cz * _qn + cx


func water_dist_q(p: Vector2) -> float:
	var i := _gidx(p)
	if _g_water_set[i] != 0:
		memo_hits += 1
		return _g_water[i]
	memo_miss += 1
	var v: float = _water_dist(p)
	_g_water[i] = v
	_g_water_set[i] = 1
	return v


func major_gap_q(p: Vector2) -> float:
	var i := _gidx(p)
	if _g_major_set[i] != 0:
		return _g_major[i]
	var v: float = _road_gap(p)
	_g_major[i] = v
	_g_major_set[i] = 1
	return v


func intensity_q(p: Vector2) -> float:
	var i := _gidx(p)
	if _g_inten_set[i] != 0:
		return _g_inten[i]
	var v: float = intensity_at(p)
	_g_inten[i] = v
	_g_inten_set[i] = 1
	return v


func district_q(p: Vector2) -> Dictionary:
	var k := Vector2i(int(round(p.x / 100.0)), int(round(p.y / 100.0)))
	if _q_district.has(k):
		return _q_district[k]
	var v: Dictionary = district_at(p)
	_q_district[k] = v
	return v


func memo_stats() -> Dictionary:
	return {"hits": memo_hits, "miss": memo_miss, "cells": _qn * _qn}


func clear_memo() -> void:
	_g_water_set.fill(0)
	_g_major_set.fill(0)
	_g_inten_set.fill(0)
	_g_park_set.fill(0)
	_q_district.clear()


func river_flow_at(p: Vector2) -> Vector2:
	var best_d := 1e9
	var along := Vector2.RIGHT
	for i in range(_seg_a.size()):
		var a: Vector2 = _seg_a[i]
		var ab: Vector2 = _seg_b[i] - a
		var len2 := ab.length_squared()
		var t := 0.0 if len2 < 0.0001 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
		var d := p.distance_to(a + ab * t)
		if d < best_d:
			best_d = d
			along = ab.normalized() if len2 > 0.0001 else Vector2.RIGHT
	return along


# --- Urban queries ----------------------------------------------------------
func district_at(p: Vector2) -> Dictionary:
	var best: Dictionary = RURAL
	var best_score := 1e18
	for d in DISTRICTS:
		var dx: float = p.x - d["cx"]
		var dz: float = p.y - d["cz"]
		var r: float = d["r"]
		var score: float = (dx * dx + dz * dz) / maxf(r * r, 1.0)
		if score < best_score:
			best_score = score
			best = d
	return best


## 0..1 urban intensity: peaks at People's Square, secondary peaks at sub-centres,
## and — as in the real city — rises again along the water frontage.
func intensity_at(p: Vector2) -> float:
	var base := 1.0 - clampf(p.length() / 5800.0, 0.0, 1.0)
	base = pow(base, 0.72)
	var d := district_q(p)
	base *= 0.55 + 0.45 * float(d["density"])
	var wd := absf(water_dist_q(p))
	if wd < 750.0:
		base *= 1.0 + 0.25 * (1.0 - wd / 750.0)
	for sub in SUB_CENTRES:
		var sd := p.distance_to(sub)
		if sd < 1400.0:
			base = maxf(base, 0.28 + 0.42 * (1.0 - sd / 1400.0))
	return clampf(base, 0.02, 1.0)


const SUB_CENTRES := [
	Vector2(4350, 1900), Vector2(-1180, 2720), Vector2(2780, -4050),
	Vector2(-3900, 400), Vector2(1200, 3600), Vector2(-2400, 4600),
]


func height_range_at(p: Vector2) -> Vector2:
	var d := district_q(p)
	var k := intensity_q(p)
	var lo := lerpf(6.0, float(d["hmin"]), clampf(k * 1.15, 0.0, 1.0))
	var hi := lerpf(20.0, float(d["hmax"]), clampf(k * 1.05, 0.0, 1.0))
	return Vector2(lo, maxf(hi, lo + 6.0))


## Signed distance to the nearest park boundary — negative inside. One radius scan serves
## every "is this open ground" caller; the gate used to loop all parks from the edge tests,
## the ground grid and the population census.
func park_dist_q(p: Vector2) -> float:
	var i := _gidx(p)
	if _g_park_set[i] != 0:
		return _g_park[i]
	var best := 1e9
	for pk in PARKS:
		var dx: float = p.x - pk["x"]
		var dz: float = p.y - pk["z"]
		var d: float = sqrt(dx * dx + dz * dz) - float(pk["r"])
		if d < best:
			best = d
	_g_park[i] = best
	_g_park_set[i] = 1
	return best


func in_park(p: Vector2) -> bool:
	return park_dist_q(p) < 0.0


## margin grows or shrinks every park radius, so a point just outside a park can still be
## asked to yield a setback.
func blocks_building(p: Vector2, margin: float = 0.0) -> bool:
	if absf(p.x) > GameGlobals.WORLD_HALF or absf(p.y) > GameGlobals.WORLD_HALF:
		return true
	if water_dist_q(p) < 0.0:
		return true
	return park_dist_q(p) < margin


## Distance to the nearest road centreline minus half its width — negative means
## the point sits on asphalt, which is what the block generator uses to cut plots.
func road_clearance(p: Vector2) -> float:
	var best: float = _road_gap(p)
	for lm in LANDMARKS:
		var footprint: float = landmark_footprint(lm)
		var d2: float = Vector2(lm["x"], lm["z"]).distance_to(p) - footprint
		if d2 < best:
			best = d2
	return best


func landmark_footprint(lm: Dictionary) -> float:
	if lm.has("r"):
		return float(lm["r"])
	match lm["type"]:
		"bund_row":
			return float(lm.get("len", 1200.0)) * 0.5
		"pudong_airport":
			return 1500.0
		"hongqiao_hub":
			return 700.0
		"disney_castle":
			return 620.0
		"stadium":
			return 260.0
		"pearl_tower":
			return 170.0
		"yuyuan":
			return 300.0
		"wujiaochang":
			return 300.0
		"plaza":
			return 340.0
		_:
			return 95.0


## True when p falls inside the clearing around a landmark, so procedural towers never grow
## through the icons. Linear landmarks (The Bund) measure distance to their *axis*, not to
## their centre — a 1.5 km facade row is not a 750 m radius disc.
func in_landmark_zone(p: Vector2) -> bool:
	for lm in LANDMARKS:
		var c := Vector2(lm["x"], lm["z"])
		if String(lm["type"]) == "bund_row":
			var half: float = float(lm.get("len", 1200.0)) * 0.5
			var rot: float = float(lm.get("rot", 0.0))
			var ax := Vector2(cos(rot), sin(rot))
			var t := clampf((p - c).dot(ax) / maxf(half, 1.0), -1.0, 1.0)
			if p.distance_to(c + ax * t * half) < float(lm.get("clear", 80.0)):
				return true
			continue
		if c.distance_to(p) < float(lm.get("clear", 95.0)):
			return true
	return false


func _poly_distance(path: PackedVector2Array, p: Vector2) -> float:
	var best := 1e9
	for i in range(path.size() - 1):
		var a := path[i]
		var ab := path[i + 1] - a
		var len2 := ab.length_squared()
		var t := 0.0 if len2 < 0.0001 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


## Landmarks that can touch this chunk. Returns a shared empty array rather than a fresh
## literal so no caller, hot or cold, allocates on a miss.
const NO_LANDMARKS: Array = []


func landmarks_in(chunk: Vector2i) -> Array:
	if not landmark_cells.has(chunk):
		return NO_LANDMARKS
	return landmark_cells[chunk]


## Roads that can touch this chunk, expanded to world space.
func roads_near(center: Vector2, radius: float) -> Array:
	var out: Array = []
	for r in roads:
		var path: PackedVector2Array = r["path"]
		for i in path.size():
			if path[i].distance_to(center) <= radius:
				out.append(r)
				break
	return out


# --- Major-road spatial index ------------------------------------------------
## Rings carry 257 sampled points each, so a linear scan per plot would dominate build
## time. Bucket every segment once, then reject whole buckets by their distance to the
## query point before touching any segment inside them.
var _rs_a: PackedVector2Array
var _rs_b: PackedVector2Array
var _rs_w: PackedFloat32Array
var _rs_deck: PackedFloat32Array
var _rs_elev: PackedByteArray
var _rs_lane: PackedInt32Array
var _rs_name: Array[String] = []
var _road_grid: Dictionary = {}
var _road_cell := 250.0
var _road_half_max := 24.0


func _index_roads() -> void:
	_rs_a.resize(0)
	_rs_b.resize(0)
	_rs_w.resize(0)
	_rs_deck.resize(0)
	_rs_elev.resize(0)
	_rs_lane.resize(0)
	_rs_name.clear()
	_road_grid.clear()
	for r in roads:
		var path: PackedVector2Array = r["path"]
		var w: float = r["width"]
		var elevated: bool = r["elevated"]
		var deck: float = r["deck_y"]
		var lanes: int = int(r["lanes"])
		var nm: String = r["name"]
		_road_half_max = maxf(_road_half_max, w * 0.5)
		for i in range(path.size() - 1):
			var a: Vector2 = path[i]
			var b: Vector2 = path[i + 1]
			# Keep ring segments off-map out of the index entirely.
			if absf(a.x) > GameGlobals.WORLD_HALF + 900.0 and absf(b.x) > GameGlobals.WORLD_HALF + 900.0:
				continue
			if absf(a.y) > GameGlobals.WORLD_HALF + 900.0 and absf(b.y) > GameGlobals.WORLD_HALF + 900.0:
				continue
			var idx := _rs_a.size()
			_rs_a.append(a)
			_rs_b.append(b)
			_rs_w.append(w)
			_rs_deck.append(deck)
			_rs_elev.append(1 if elevated else 0)
			_rs_lane.append(lanes)
			_rs_name.append(nm)
			var c0 := Vector2i(int(floor(a.x / _road_cell)), int(floor(a.y / _road_cell)))
			var c1 := Vector2i(int(floor(b.x / _road_cell)), int(floor(b.y / _road_cell)))
			for cx in range(mini(c0.x, c1.x) - 1, maxi(c0.x, c1.x) + 2):
				for cz in range(mini(c0.y, c1.y) - 1, maxi(c0.y, c1.y) + 2):
					var key := Vector2i(cx, cz)
					if not _road_grid.has(key):
						_road_grid[key] = []
					(_road_grid[key] as Array).append(idx)


## Gap from p to the nearest carriage edge; negative means p is on asphalt.
func _road_gap(p: Vector2) -> float:
	var cx := int(floor(p.x / _road_cell))
	var cz := int(floor(p.y / _road_cell))
	var best := 1e9
	for k in _off.size():
		if _off_lb[k] * _road_cell - _road_half_max >= best:
			break
		var o := _off[k]
		var key := Vector2i(cx + o.x, cz + o.y)
		if not _road_grid.has(key):
			continue
		var bx := float(key.x) * _road_cell
		var dx := maxf(maxf(bx - p.x, p.x - (bx + _road_cell)), 0.0)
		var bz := float(key.y) * _road_cell
		var dz := maxf(maxf(bz - p.y, p.y - (bz + _road_cell)), 0.0)
		if sqrt(dx * dx + dz * dz) - _road_half_max >= best:
			continue
		for v in (_road_grid[key] as Array):
			var a: Vector2 = _rs_a[v]
			var ab: Vector2 = _rs_b[v] - a
			var len2 := ab.length_squared()
			var t := 0.0 if len2 < 0.0001 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var gap := p.distance_to(a + ab * t) - _rs_w[v] * 0.5
			if gap < best:
				best = gap
	return best


## Nearest major road: gap to its edge plus heading, used to carve plots and orient blocks.
func major_road_info(p: Vector2) -> Dictionary:
	var cx := int(floor(p.x / _road_cell))
	var cz := int(floor(p.y / _road_cell))
	var best := -1
	var best_gap := 1e9
	for ox in range(-4, 5):
		var bx := float(cx + ox) * _road_cell
		var dx := maxf(maxf(bx - p.x, p.x - (bx + _road_cell)), 0.0)
		if dx - _road_half_max >= best_gap:
			continue
		for oz in range(-4, 5):
			var bz := float(cz + oz) * _road_cell
			var dz := maxf(maxf(bz - p.y, p.y - (bz + _road_cell)), 0.0)
			if sqrt(dx * dx + dz * dz) - _road_half_max >= best_gap:
				continue
			var key := Vector2i(cx + ox, cz + oz)
			if not _road_grid.has(key):
				continue
			for v in (_road_grid[key] as Array):
				var a: Vector2 = _rs_a[v]
				var ab: Vector2 = _rs_b[v] - a
				var len2 := ab.length_squared()
				var t := 0.0 if len2 < 0.0001 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
				var gap := p.distance_to(a + ab * t) - _rs_w[v] * 0.5
				if gap < best_gap:
					best_gap = gap
					best = v
	if best < 0:
		return {"gap": 1e9, "dist": 1e9, "width": 0.0, "along": Vector2.RIGHT,
			"elevated": false, "deck": 0.0, "lanes": 0, "name": ""}
	var ab2: Vector2 = _rs_b[best] - _rs_a[best]
	return {"gap": best_gap, "dist": best_gap + _rs_w[best] * 0.5, "width": _rs_w[best],
		"along": ab2.normalized(), "elevated": _rs_elev[best] == 1, "deck": _rs_deck[best],
		"lanes": _rs_lane[best], "name": _rs_name[best]}


func near_major_road(p: Vector2, slack: float = 0.0) -> bool:
	return _road_gap(p) < slack


# --- Typed accessors --------------------------------------------------------
## Dictionary payloads force every caller into Variant; these keep generation typed.
func major_gap(p: Vector2) -> float:
	return major_gap_q(p)


func major_elevated_at(p: Vector2) -> bool:
	return bool(major_road_info(p)["elevated"])


func district_style(p: Vector2) -> String:
	return String(district_q(p)["style"])


func district_density(p: Vector2) -> float:
	return float(district_at(p)["density"])


func road_seg_count() -> int:
	return _rs_a.size()

