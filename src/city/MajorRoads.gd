class_name MajorRoads
extends Node3D
## The ring + radial skeleton: 内环 / 中环 / 外环 plus the named avenues. This is the layer
## that gives Shanghai its legibility, and it is global rather than chunked because a ring
## road that stops at a streaming boundary is useless.
##
## Crossing the Huangpu is handled the way the real city does it: an elevated expressway
## disappears into a river tunnel, an at-grade boulevard comes up as a bridge.

const DENSIFY := 12.0
const SIDE_W := 4.2
const LAMP_STEP := 52.0
const PIER_STEP := 34.0
const BRIDGE_Y := 9.0
const WATER_Z := -0.55

var _asphalt: Dictionary = {}
var _props := MeshFusion.new()
var _emissive := MeshFusion.new()
var _lamp_count := 0
var _deck_len := 0.0
var _tunnels: Array = []
var _bridges: int = 0


func _ready() -> void:
	for r in CityData.roads:
		_road(r)
	_commit()


# --- Sampling ---------------------------------------------------------------
func _densify(path: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var seg := b - a
		var l := seg.length()
		if l < 0.001:
			continue
		var n := maxi(int(ceil(l / step)), 1)
		for k in n:
			out.append(a + seg * (float(k) / float(n)))
	out.append(path[path.size() - 1])
	return out


## Split a polyline into runs of the same "over water" state.
func _runs(pts: PackedVector2Array) -> Array:
	var out: Array = []
	var start := 0
	var cur := CityData.in_water(pts[0])
	for i in range(1, pts.size()):
		var v := CityData.in_water(pts[i])
		if v != cur:
			out.append({"a": start, "b": i, "water": cur})
			start = i
			cur = v
	out.append({"a": start, "b": pts.size() - 1, "water": cur})
	return out


## A polyline shifted sideways by `dist` metres (positive = left of travel).
func _offset_poly(poly: PackedVector2Array, dist: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := poly.size()
	for i in n:
		var a := poly[mini(maxi(i - 1, 0), n - 1)]
		var b := poly[mini(i + 1, n - 1)]
		var dir := b - a
		if dir.length_squared() < 0.0001:
			out.append(poly[i])
			continue
		out.append(poly[i] + Vector2(-dir.y, dir.x) / dir.length() * dist)
	return out


# --- Assembly ---------------------------------------------------------------
func _road(r: Dictionary) -> void:
	var path: PackedVector2Array = r["path"]
	if path.size() < 2:
		return
	var pts := _densify(path, DENSIFY)
	var w: float = r["width"]
	var lanes: int = int(r["lanes"])
	var elevated: bool = r["elevated"]
	var deck: float = float(r["deck_y"])
	var key := "%d_%d" % [lanes, int(round(w))]
	if not _asphalt.has(key):
		_asphalt[key] = {"f": MeshFusion.new(), "lanes": lanes, "w": w}
	var bag: Dictionary = _asphalt[key]
	var fusion: MeshFusion = bag["f"]
	var asphalt := Color(0, 0, 0)
	asphalt.a = 0.0
	for run in _runs(pts):
		var i0: int = run["a"]
		var i1: int = run["b"]
		if i1 - i0 < 1:
			continue
		var sub := pts.slice(i0, i1 + 1)
		if sub.size() < 2:
			continue
		var arcs := MeshFusion.arc_lengths(sub)
		_deck_len += arcs[arcs.size() - 1]
		if run["water"]:
			if elevated:
				_tunnels.append(String(r["name"]))
				continue
			_bridges += 1
			_bridge(sub, arcs, w, fusion, asphalt)
		elif elevated:
			_viaduct(sub, arcs, w, deck, fusion, asphalt)
		else:
			_at_grade(sub, arcs, w, fusion, asphalt)


func _at_grade(sub: PackedVector2Array, arcs: PackedFloat32Array, w: float,
		fusion: MeshFusion, asphalt: Color) -> void:
	fusion.ribbon(sub, w * 0.5, 0.06, 0.06, asphalt, arcs)
	var pave := Color(0.46, 0.45, 0.44)
	pave.a = 2.0
	var kerb := Color(0.55, 0.545, 0.53)
	kerb.a = 4.0
	for side in [-1, 1]:
		var walk := _offset_poly(sub, float(side) * (w * 0.5 + SIDE_W * 0.5))
		_props.ribbon(walk, SIDE_W * 0.5, 0.15, 0.15, pave, MeshFusion.arc_lengths(walk))
		var edge := _offset_poly(sub, float(side) * (w * 0.5))
		_props.skirt(edge, 0.0, 0.15, 0.0, kerb, MeshFusion.arc_lengths(edge), -side)
	_lamps(sub, w * 0.5 + SIDE_W - 0.6)


## 高架 — a deck on twin-column piers with barriers, like 延安高架 / 南北高架.
func _viaduct(sub: PackedVector2Array, arcs: PackedFloat32Array, w: float, deck: float,
		fusion: MeshFusion, asphalt: Color) -> void:
	var hw := w * 0.5 + 0.5
	fusion.ribbon(sub, hw, deck, deck, asphalt, arcs)
	var conc := Color(0.50, 0.495, 0.48)
	conc.a = 4.0
	var rail := Color(0.58, 0.59, 0.61)
	rail.a = 4.0
	_props.skirt(sub, hw, deck, deck - 1.3, conc, arcs, 1)
	_props.skirt(sub, hw, deck, deck - 1.3, conc, arcs, -1)
	_piers(sub, deck, hw, conc)
	for side in [-1, 1]:
		_props.skirt(sub, hw - 0.25, deck + 1.15, deck - 0.05, rail, arcs, side)


func _bridge(sub: PackedVector2Array, arcs: PackedFloat32Array, w: float,
		fusion: MeshFusion, asphalt: Color) -> void:
	var y0 := 0.06
	var y1 := BRIDGE_Y
	var hw := w * 0.5 + 0.6
	fusion.ribbon(sub, hw, y0, y1, asphalt, arcs)
	var conc := Color(0.50, 0.495, 0.48)
	conc.a = 4.0
	var rail := Color(0.60, 0.61, 0.63)
	rail.a = 4.0
	for side in [-1, 1]:
		_sloped_wall(sub, hw, y0, y1, 0.0, -1.6, side, conc)
		_sloped_wall(sub, hw - 0.25, y0, y1, 1.15, 0.0, side, rail)
	# Piers down to the bed at intervals along the span.
	var n := maxi(int(float(sub.size()) / 14.0), 2)
	for k in range(1, n):
		var i := int(float(k) / float(n) * float(sub.size() - 1))
		var p: Vector2 = sub[i]
		var t := float(i) / float(maxi(sub.size() - 1, 1))
		var y := lerpf(y0, y1, t)
		_props.box(Transform3D(Basis.IDENTITY, Vector3(p.x, WATER_Z, p.y)),
			Vector3(3.2, maxf(y - WATER_Z + 2.0, 2.0), 3.2), conc)


## A wall whose top and bottom follow the ramp of the deck — bridge fascia and parapets,
## where a constant-height skirt would float off the sloping surface.
func _sloped_wall(sub: PackedVector2Array, off: float, y0: float, y1: float,
		d_top: float, d_bot: float, side: int, c: Color) -> void:
	var n := sub.size()
	for i in range(n - 1):
		var a := sub[i]
		var b := sub[i + 1]
		var dir := b - a
		var l := dir.length()
		if l < 0.001:
			continue
		var s := Vector2(-dir.y, dir.x) / l * float(side) * off
		var ta := float(i) / float(maxi(n - 1, 1))
		var tb := float(i + 1) / float(maxi(n - 1, 1))
		var ya := lerpf(y0, y1, ta)
		var yb := lerpf(y0, y1, tb)
		var nrm := Vector3(s.x, 0.0, s.y).normalized()
		_props.quad(
			Vector3(a.x + s.x, ya + d_bot, a.y + s.y),
			Vector3(b.x + s.x, yb + d_bot, b.y + s.y),
			Vector3(b.x + s.x, yb + d_top, b.y + s.y),
			Vector3(a.x + s.x, ya + d_top, a.y + s.y), nrm, c)


func _piers(sub: PackedVector2Array, deck: float, hw: float, conc: Color) -> void:
	var acc := 0.0
	for i in range(1, sub.size()):
		acc += sub[i - 1].distance_to(sub[i])
		if acc < PIER_STEP:
			continue
		acc = 0.0
		var p: Vector2 = sub[i]
		var dir := (sub[i] - sub[i - 1]).normalized()
		var side := Vector2(-dir.y, dir.x)
		var yaw := atan2(-dir.x, dir.y)
		var rot := Basis.IDENTITY.rotated(Vector3.UP, yaw)
		# Twin columns straddling the carriageway with a crosshead, the standard Shanghai
		# viaduct bent — a single narrow leg reads as a signpost, not a bridge pier.
		for s in [-1, 1]:
			var q := p + side * (hw * 0.62) * float(s)
			_props.box(Transform3D(rot, Vector3(q.x, 0.0, q.y)),
				Vector3(1.3, maxf(deck - 1.6, 1.0), 1.9), conc)
		_props.box(Transform3D(rot, Vector3(p.x, deck - 1.55, p.y)),
			Vector3(hw * 2.2, 0.9, 1.5), conc)


func _lamps(sub: PackedVector2Array, off: float) -> void:
	var steel := Color(0.30, 0.31, 0.33)
	steel.a = 4.0
	var acc := 0.0
	var side := 1.0
	for i in range(1, sub.size()):
		acc += sub[i - 1].distance_to(sub[i])
		if acc < LAMP_STEP:
			continue
		acc = 0.0
		side = -side
		var dir := (sub[i] - sub[i - 1]).normalized()
		var n := Vector2(-dir.y, dir.x) * side
		var base: Vector2 = sub[i] + n * off
		if CityData.in_water(base):
			continue
		var hgt := 9.2
		var xf := Transform3D(Basis.IDENTITY, Vector3(base.x, 0.0, base.y))
		_props.cylinder(xf, 0.19, 0.11, hgt, steel, 6, false)
		var arm := n * 1.9
		_props.box(Transform3D(Basis.IDENTITY,
			Vector3(base.x + arm.x * 0.5, hgt - 0.2, base.y + arm.y * 0.5)),
			Vector3(2.1, 0.18, 0.18), steel)
		_emissive.box(Transform3D(Basis.IDENTITY,
			Vector3(base.x + arm.x, hgt - 0.6, base.y + arm.y)),
			Vector3(1.15, 0.34, 0.46), Color(1.0, 0.84, 0.58))
		_lamp_count += 1


func _commit() -> void:
	for key in _asphalt.keys():
		var bag: Dictionary = _asphalt[key]
		var fusion: MeshFusion = bag["f"]
		if fusion.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = fusion.commit()
		mi.material_overlay = Assets.road_mat(int(bag["lanes"]), true, float(bag["w"]))
		mi.extra_cull_margin = 300.0
		add_child(mi)
	if not _props.is_empty():
		var mi2 := MeshInstance3D.new()
		mi2.mesh = _props.commit()
		mi2.material_overlay = Assets.props_mat()
		mi2.extra_cull_margin = 200.0
		mi2.visibility_range_end = 2800.0
		mi2.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		add_child(mi2)
	if not _emissive.is_empty():
		var mi3 := MeshInstance3D.new()
		mi3.mesh = _emissive.commit()
		mi3.material_overlay = Assets.emissive_mat()
		mi3.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi3.extra_cull_margin = 200.0
		mi3.visibility_range_end = 2800.0
		add_child(mi3)


func stats() -> Dictionary:
	return {"lamps": _lamp_count, "km": _deck_len / 1000.0, "bridges": _bridges,
		"tunnels": _tunnels.size(), "tris": _props.tri_count() + _emissive.tri_count()}
