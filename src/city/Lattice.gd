class_name Lattice
extends RefCounted
## Block lattice — the skeleton the whole city hangs off.
##
## Cells are superblocks; streets are the *dual graph* (edges between neighbouring cell
## centres). That makes the network seam-free by construction: cell_centre() is a pure
## function of (i, j), so two chunks that both touch a cell agree exactly on where its
## streets and plot boundaries fall, with no cross-chunk state.
##
## The lattice is deliberately warped rather than a pure grid. Real Puxi streets curve,
## and a warped dual graph gives that at no runtime cost. Absent edges merge adjacent
## cells into a larger superblock, which is how Shanghai jumps from a 90 m lane to a
## 400 m walled estate without any special casing.

const BASE_U := 104.0
const BASE_V := 116.0
const JITTER := 0.13
const EDGE_KEEP := 0.74
const MINOR_PROB := 0.30

const CELL_KINDS := [
	"SPLIT_TOWER", "XIAOQU", "LILONG", "SHOPFRONT_ROW", "MALL", "OFFICE_PLINTH",
	"PARK_CELL", "FACTORY", "VILLAS", "PARKING", "SITE", "DENSE_WALKUP",
]


## Centre of cell (i, j) in world metres. Memoised: cell_at() fans out over a 5×5 index
## window for every ground cell, and recomputing the warp made a single chunk cost ~70 ms.
static var _center_cache: Dictionary = {}


static func cell_center(i: int, j: int) -> Vector2:
	var ck := Vector2i(i, j)
	if _center_cache.has(ck):
		return _center_cache[ck]
	var base := Vector2(float(i) * BASE_U, float(j) * BASE_V)
	base += Vector2(sin(base.y * 0.00043) * 195.0, cos(base.x * 0.00051) * 165.0)
	var th := 0.215 * sin(base.y / 2340.0) + 0.152 * cos(base.x / 2710.0) + 0.07 * sin((base.x + base.y) / 1580.0)
	base = base.rotated(th)
	var h := GameGlobals.hash2(i, j, 17)
	base += Vector2(h - 0.5, GameGlobals.hash2(i, j, 23) - 0.5) * Vector2(BASE_U * JITTER * 2.0, BASE_V * JITTER * 2.0)
	_center_cache[ck] = base
	return base


## True when a street runs between (i, j) and its neighbour along axis (0 = +x, 1 = +z).
## Cached on (cell, axis): every ground grid, street pass and census re-asks the same edges
## from up to four chunks.
static var _edge_cache: Dictionary = {}


static func edge_present(i: int, j: int, axis: int) -> bool:
	var ck := Vector2i(i * 2 + axis, j)
	if _edge_cache.has(ck):
		return _edge_cache[ck]
	var v: bool = _edge_raw(i, j, axis)
	_edge_cache[ck] = v
	return v


static func _edge_raw(i: int, j: int, axis: int) -> bool:
	var s := 31 if axis == 0 else 57
	# Both endpoints must be buildable land for a lane to exist.
	var a := cell_center(i, j)
	var b := cell_center(i + (1 if axis == 0 else 0), j + (1 if axis == 1 else 0))
	for p in [a, b]:
		if CityData.blocks_building(p, -40.0):
			return false
	# A cell that sits on a major road has its own frontage already.
	if CityData.major_gap((a + b) * 0.5) < 6.0:
		return false
	var h := GameGlobals.hash2(i * 2 + axis, j * 2, s)
	if h > EDGE_KEEP:
		return false
	# Long straight runs: occasionally force a corridor so the grid keeps legibility.
	if axis == 0 and (j % 7 == 0):
		return true
	if axis == 1 and (i % 6 == 0):
		return true
	# Absent edges are what merge two cells into one larger superblock; the threshold above
	# is the only gate, so a second one here would silently halve the street network.
	return true


static func edge_width(i: int, j: int, axis: int) -> float:
	var h := GameGlobals.hash2(i * 2 + axis, j * 2, 71)
	if h > 0.86:
		return 16.0
	if h > 0.60:
		return 12.5
	return 8.5


## Direction-agnostic edge test, so agents can walk or drive backwards along the graph.
static func edge_between(a: Vector2i, b: Vector2i) -> bool:
	var d := b - a
	if d == Vector2i(1, 0):
		return edge_present(a.x, a.y, 0)
	if d == Vector2i(-1, 0):
		return edge_present(b.x, b.y, 0)
	if d == Vector2i(0, 1):
		return edge_present(a.x, a.y, 1)
	if d == Vector2i(0, -1):
		return edge_present(b.x, b.y, 1)
	return false


## Reachable neighbours of a node. The graph is implicit — derived from cell indices on
## demand — so it needs no build pass and covers the whole 12 km map for free.
##
## Memoised because the graph is static and edge_present() is not cheap: it asks whether
## both endpoints are dry land and whether a major road already owns the corridor. Crowd and
## traffic agents hit this on every node arrival, so without the cache the graph lookup
## alone cost more per frame than the entire streaming rebuild.
static var _nbr_cache: Dictionary = {}


static func neighbors(a: Vector2i) -> Array:
	if _nbr_cache.has(a):
		return _nbr_cache[a]
	var out: Array = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if edge_between(a, a + d):
			out.append(a + d)
	_nbr_cache[a] = out
	return out


static func edge_of(a: Vector2i, b: Vector2i) -> float:
	var d := b - a
	if d.x != 0:
		return edge_width(mini(a.x, b.x), a.y, 0)
	return edge_width(a.x, mini(a.y, b.y), 1)


## A street edge whose midpoint lies near p, for seeding agents. The rounded index of p is
## only a hint — the lattice warp displaces cell centres by up to ~200 m — so the naive
## lookup silently misses and callers fall back to stacking agents on top of each other.
static func random_edge_near(p: Vector2, span: int, rnd: RandomNumberGenerator) -> Dictionary:
	var i0 := int(round(p.x / BASE_U))
	var j0 := int(round(p.y / BASE_V))
	var cands: Array = []
	for dj in range(-span, span + 1):
		for di in range(-span, span + 1):
			var node := Vector2i(i0 + di, j0 + dj)
			for tgt in neighbors(node):
				var mid := (cell_center(node.x, node.y)
					+ cell_center(tgt.x, tgt.y)) * 0.5
				cands.append({"node": node, "target": tgt, "d": mid.distance_to(p)})
	if cands.is_empty():
		return {}
	# Closest, not first-found: a shuffled pick put every agent 100 m+ away from the viewer.
	cands.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var pool: Array = []
	for k in mini(4, cands.size()):
		pool.append(cands[k])
	var pick: Dictionary = pool[rnd.randi_range(0, pool.size() - 1)]
	return {"node": pick["node"], "target": pick["target"]}


## The four plot-boundary corners of a cell: midpoints toward each neighbour.
static func cell_quad(i: int, j: int) -> PackedVector2Array:
	var c := cell_center(i, j)
	var e := cell_center(i + 1, j)
	var w := cell_center(i - 1, j)
	var n := cell_center(i, j - 1)
	var s := cell_center(i, j + 1)
	return PackedVector2Array([
		(c + n) * 0.5, (e + c) * 0.5, (c + s) * 0.5, (w + c) * 0.5,
	])


## Local street centrelines crossing this cell, as segments to draw.
static func cell_streets(i: int, j: int) -> Array:
	var out: Array = []
	var c := cell_center(i, j)
	var pairs := [
		[Vector2i(i + 1, j), 0], [Vector2i(i, j + 1), 1],
	]
	for pr in pairs:
		var nb: Vector2i = pr[0]
		var axis: int = pr[1]
		if not edge_present(i, j, axis):
			continue
		var o := cell_center(nb.x, nb.y)
		out.append({"a": c, "b": o, "w": edge_width(i, j, axis)})
	return out


static var _kind_cache: Dictionary = {}


static func cell_kind(i: int, j: int) -> String:
	var ck := Vector2i(i, j)
	var cached: String = _kind_cache.get(ck, "")
	if cached != "":
		return cached
	var v: String = _kind_raw(i, j)
	_kind_cache[ck] = v
	return v


static func _kind_raw(i: int, j: int) -> String:
	var c := cell_center(i, j)
	var d := CityData.district_q(c)
	var style: String = d["style"]
	var k := CityData.intensity_q(c)
	var h := GameGlobals.hash2(i, j, 101)
	match style:
		"cbd_tower":
			if h < 0.30:
				return "MALL"
			if h < 0.52:
				return "OFFICE_PLINTH"
			if h < 0.62:
				return "PARK_CELL"
			return "SPLIT_TOWER"
		"historic_mix":
			if h < 0.24:
				return "LILONG"
			if h < 0.42:
				return "DENSE_WALKUP"
			if h < 0.56:
				return "SHOPFRONT_ROW"
			if h < 0.66:
				return "MALL"
			if h < 0.72:
				return "SITE"
			return "XIAOQU" if k > 0.45 else "LILONG"
		"modern_mix":
			if h < 0.34:
				return "XIAOQU"
			if h < 0.52:
				return "SPLIT_TOWER"
			if h < 0.64:
				return "SHOPFRONT_ROW"
			if h < 0.70:
				return "PARKING"
			if h < 0.76:
				return "MALL"
			return "DENSE_WALKUP"
		"old_industrial", "port_industry":
			if h < 0.40:
				return "FACTORY"
			if h < 0.55:
				return "PARKING"
			if h < 0.68:
				return "VILLAS"
			if h < 0.78:
				return "SITE"
			return "DENSE_WALKUP"
		"campus_industrial":
			if h < 0.30:
				return "FACTORY"
			if h < 0.48:
				return "SPLIT_TOWER"
			if h < 0.62:
				return "XIAOQU"
			if h < 0.70:
				return "PARK_CELL"
			return "DENSE_WALKUP"
		"diplomatic":
			if h < 0.52:
				return "VILLAS"
			if h < 0.66:
				return "PARK_CELL"
			if h < 0.78:
				return "OFFICE_PLINTH"
			return "XIAOQU"
		"sprawl_tower":
			if h < 0.46:
				return "XIAOQU"
			if h < 0.62:
				return "DENSE_WALKUP"
			if h < 0.72:
				return "MALL"
			if h < 0.80:
				return "PARKING"
			return "SPLIT_TOWER"
		"suburb":
			if h < 0.44:
				return "VILLAS"
			if h < 0.62:
				return "XIAOQU"
			if h < 0.74:
				return "PARK_CELL"
			if h < 0.84:
				return "FACTORY"
			return "PARKING"
		_:
			if h < 0.5:
				return "VILLAS"
			if h < 0.7:
				return "FACTORY"
			return "PARK_CELL"


## Convex-kite point test used when a block rasterises its own ground slots.
static func quad_has(poly: PackedVector2Array, p: Vector2) -> bool:
	var inside := false
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		if (a.y > p.y) != (b.y > p.y):
			var t := (p.y - a.y) / (b.y - a.y)
			if p.x < a.x + (b.x - a.x) * t:
				inside = not inside
	return inside


## Cells that can touch a world-space rect.
static func cells_in_rect(min_p: Vector2, max_p: Vector2, pad: float = 0.0) -> Array:
	# The warp is bounded, so an index window slightly larger than the rect covers it.
	var slack := pad + 200.0
	var lo := Vector2(min_p.x - slack, min_p.y - slack)
	var hi := Vector2(max_p.x + slack, max_p.y + slack)
	var out: Array = []
	var i0 := int(floor(lo.x / BASE_U)) - 2
	var i1 := int(ceil(hi.x / BASE_U)) + 2
	var j0 := int(floor(lo.y / BASE_V)) - 2
	var j1 := int(ceil(hi.y / BASE_V)) + 2
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			var c := cell_center(i, j)
			if c.x < lo.x - BASE_U or c.x > hi.x + BASE_U:
				continue
			if c.y < lo.y - BASE_V or c.y > hi.y + BASE_V:
				continue
			out.append(Vector2i(i, j))
	return out
