class_name MeshFusion
extends RefCounted
## Accumulates transformed primitives into one surface so a whole city block renders as a
## single draw call. UVs are metric metres, which is what the procedural shaders expect.
## Vertex colour alpha carries a shader flag and must not be used for opacity.

var verts: PackedVector3Array = PackedVector3Array()
var norms: PackedVector3Array = PackedVector3Array()
var cols: PackedColorArray = PackedColorArray()
var uvs: PackedVector2Array = PackedVector2Array()
var idx: PackedInt32Array = PackedInt32Array()


func is_empty() -> bool:
	return verts.is_empty()


func vertex_count() -> int:
	return verts.size()


func tri_count() -> int:
	return idx.size() / 3


func clear() -> void:
	verts.clear()
	norms.clear()
	cols.clear()
	uvs.clear()
	idx.clear()


func commit() -> ArrayMesh:
	var am := ArrayMesh.new()
	if verts.is_empty():
		return am
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


func aabb_of() -> AABB:
	if verts.is_empty():
		return AABB()
	var a := AABB(verts[0], Vector3.ZERO)
	for v in verts:
		a = a.expand(v)
	return a


# --- Low level --------------------------------------------------------------
func quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, normal: Vector3, col: Color) -> void:
	var base := verts.size()
	verts.append(p0); verts.append(p1); verts.append(p2); verts.append(p3)
	norms.append(normal); norms.append(normal); norms.append(normal); norms.append(normal)
	for k in 4:
		cols.append(col)
	uvs.append(_planar_uv(p0, normal)); uvs.append(_planar_uv(p1, normal))
	uvs.append(_planar_uv(p2, normal)); uvs.append(_planar_uv(p3, normal))
	idx.append(base); idx.append(base + 1); idx.append(base + 2)
	idx.append(base); idx.append(base + 2); idx.append(base + 3)


func triangle(p0: Vector3, p1: Vector3, p2: Vector3, normal: Vector3, col: Color) -> void:
	var base := verts.size()
	verts.append(p0); verts.append(p1); verts.append(p2)
	norms.append(normal); norms.append(normal); norms.append(normal)
	cols.append(col); cols.append(col); cols.append(col)
	uvs.append(_planar_uv(p0, normal)); uvs.append(_planar_uv(p1, normal)); uvs.append(_planar_uv(p2, normal))
	idx.append(base); idx.append(base + 1); idx.append(base + 2)


## Facades are unrolled on the dominant horizontal axis; caps use the XZ plane.
func _planar_uv(p: Vector3, n: Vector3) -> Vector2:
	if absf(n.y) > 0.65:
		return Vector2(p.x, p.z)
	if absf(n.x) > absf(n.z):
		return Vector2(p.z, p.y)
	return Vector2(p.x, p.y)


# --- Boxes ------------------------------------------------------------------
## `box` sits on its origin (grows upward). top_scale shrinks the upper footprint, which
## is how every setback in a Shanghai tower is made.
func box(xf: Transform3D, size: Vector3, col: Color, top_scale: float = 1.0,
		top_offset: Vector2 = Vector2.ZERO, cap_bottom: bool = true) -> void:
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	var hy := size.y
	var tx := hx * top_scale
	var tz := hz * top_scale
	var b := [
		Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz),
	]
	var t := [
		Vector3(-tx + top_offset.x, hy, -tz + top_offset.y),
		Vector3(tx + top_offset.x, hy, -tz + top_offset.y),
		Vector3(tx + top_offset.x, hy, tz + top_offset.y),
		Vector3(-tx + top_offset.x, hy, tz + top_offset.y),
	]
	var rot := xf.basis.orthonormalized()
	for i in 4:
		var j := (i + 1) % 4
		var mid: Vector3 = (b[i] + b[j]) * 0.5
		var nrm := rot * Vector3(mid.x, 0.0, mid.z).normalized()
		quad(xf * b[i], xf * b[j], xf * t[j], xf * t[i], nrm, col)
	quad(xf * t[3], xf * t[2], xf * t[1], xf * t[0], rot * Vector3.UP, col)
	if cap_bottom:
		quad(xf * b[0], xf * b[1], xf * b[2], xf * b[3], rot * Vector3.DOWN, col)


## Linear box between two rectangles — sloped roofs, rakes, tapered mast sections.
func loft(xf: Transform3D, rect_a: Vector2, rect_b: Vector2, y_a: float, y_b: float,
		col: Color, offset_a: Vector2 = Vector2.ZERO, offset_b: Vector2 = Vector2.ZERO) -> void:
	var a := [
		Vector3(-rect_a.x + offset_a.x, y_a, -rect_a.y), Vector3(rect_a.x + offset_a.x, y_a, -rect_a.y),
		Vector3(rect_a.x + offset_a.x, y_a, rect_a.y), Vector3(-rect_a.x + offset_a.x, y_a, rect_a.y),
	]
	var bb := [
		Vector3(-rect_b.x + offset_b.x, y_b, -rect_b.y), Vector3(rect_b.x + offset_b.x, y_b, -rect_b.y),
		Vector3(rect_b.x + offset_b.x, y_b, rect_b.y), Vector3(-rect_b.x + offset_b.x, y_b, rect_b.y),
	]
	var rot := xf.basis.orthonormalized()
	for i in 4:
		var j := (i + 1) % 4
		var mid: Vector3 = (a[i] + bb[j]) * 0.5
		var nrm := rot * Vector3(mid.x, 0.0, mid.z).normalized()
		quad(xf * a[i], xf * a[j], xf * bb[j], xf * bb[i], nrm, col)
	quad(xf * bb[3], xf * bb[2], xf * bb[1], xf * bb[0], rot * Vector3.UP, col)
	quad(xf * a[0], xf * a[1], xf * a[2], xf * a[3], rot * Vector3.DOWN, col)


## Repeated storeys with cumulative shrink and twist. twist_deg is total over the stack.
func stack(xf: Transform3D, size: Vector3, col: Color, storeys: int,
		twist_deg: float = 0.0, taper: float = 1.0) -> void:
	var st := maxi(storeys, 1)
	var sh := size.y / float(st)
	var cur := xf
	var sx := 1.0
	for i in st:
		var s_next := 1.0 - taper * float(i + 1) / float(st)
		box(cur, Vector3(size.x * sx, sh, size.z * sx), col, maxf(s_next, 0.05) / maxf(sx, 0.001))
		sx = maxf(s_next, 0.05)
		cur = cur.translated(Vector3(0, sh, 0))
		if twist_deg != 0.0:
			cur = cur.rotated_local(Vector3.UP, deg_to_rad(twist_deg) / float(st))


# --- Rounds -----------------------------------------------------------------
func cylinder(xf: Transform3D, r_bottom: float, r_top: float, height: float,
		col: Color, seg: int = 12, caps: bool = true) -> void:
	var rot := xf.basis.orthonormalized()
	var prev := xf * Vector3(r_bottom, 0, 0)
	var prev_t := xf * Vector3(r_top, height, 0)
	for i in range(1, seg + 1):
		var a := TAU * float(i) / float(seg)
		var ca := cos(a)
		var sa := sin(a)
		var p := xf * Vector3(r_bottom * ca, 0, r_bottom * sa)
		var pt := xf * Vector3(r_top * ca, height, r_top * sa)
		quad(prev, p, pt, prev_t, rot * Vector3(ca, 0.0, sa).normalized(), col)
		prev = p
		prev_t = pt
	if caps:
		var cc_t := xf * Vector3(0, height, 0)
		var cc_b := xf * Vector3(0, 0, 0)
		for i in range(1, seg + 1):
			var a0 := TAU * float(i - 1) / float(seg)
			var a1 := TAU * float(i) / float(seg)
			triangle(cc_t, xf * Vector3(r_top * cos(a0), height, r_top * sin(a0)),
				xf * Vector3(r_top * cos(a1), height, r_top * sin(a1)), rot * Vector3.UP, col)
			triangle(cc_b, xf * Vector3(r_bottom * cos(a1), 0, r_bottom * sin(a1)),
				xf * Vector3(r_bottom * cos(a0), 0, r_bottom * sin(a0)), rot * Vector3.DOWN, col)


## UV-sphere scaled to an ellipsoid, with optional latitude window — the Pearl Tower's
## spheres and the Grand Theatre's shell are both built from this.
func ellipsoid(xf: Transform3D, radii: Vector3, col: Color, rings: int = 10, sides: int = 16,
		v_from: float = -1.0, v_to: float = 1.0) -> void:
	var rot := xf.basis.orthonormalized()
	var rr := maxi(rings, 2)
	var ss := maxi(sides, 4)
	for i in rr:
		var s0 := lerpf(v_from, v_to, float(i) / float(rr))
		var s1 := lerpf(v_from, v_to, float(i + 1) / float(rr))
		var a0 := asin(clampf(s0, -1.0, 1.0))
		var a1 := asin(clampf(s1, -1.0, 1.0))
		for j in ss:
			var b0 := TAU * float(j) / float(ss)
			var b1 := TAU * float(j + 1) / float(ss)
			var p00 := _ep(a0, b0, radii)
			var p01 := _ep(a0, b1, radii)
			var p11 := _ep(a1, b1, radii)
			var p10 := _ep(a1, b0, radii)
			var n := rot * _en(a0, b1)
			quad(xf * p00, xf * p01, xf * p11, xf * p10, n, col)


func _ep(a: float, b: float, r: Vector3) -> Vector3:
	var ca := cos(a)
	return Vector3(ca * cos(b) * r.x, sin(a) * r.y, ca * sin(b) * r.z)


func _en(a: float, b: float) -> Vector3:
	var ca := cos(a)
	return Vector3(ca * cos(b), sin(a), ca * sin(b)).normalized()


# --- Mesh import ------------------------------------------------------------
## Bakes any Godot mesh (PrimitiveMesh or ArrayMesh) into the fusion buffer.
func add_primitive(src: Mesh, xf: Transform3D, col: Color, uv_scale: float = 1.0,
		uv_offset: Vector2 = Vector2.ZERO) -> void:
	var am: Mesh = src
	if am == null or am.get_surface_count() == 0:
		return
	var rot := xf.basis.orthonormalized()
	for s in am.get_surface_count():
		var arrays := am.surface_get_arrays(s)
		var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var sn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var su: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var si: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if sv.is_empty():
			continue
		var base := verts.size()
		for i in sv.size():
			verts.append(xf * sv[i])
			norms.append(rot * sn[i] if i < sn.size() else Vector3.UP)
			cols.append(col)
			uvs.append((su[i] * uv_scale + uv_offset) if i < su.size() else _planar_uv(sv[i], sn[i] if i < sn.size() else Vector3.UP))
		if si.is_empty():
			var k := 0
			while k + 2 < sv.size():
				idx.append(base + k); idx.append(base + k + 1); idx.append(base + k + 2)
				k += 3
		else:
			for i in si:
				idx.append(base + i)


# --- Ribbons ----------------------------------------------------------------
static func arc_lengths(points: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size())
	var acc := 0.0
	for i in points.size():
		out[i] = acc
		if i < points.size() - 1:
			acc += points[i].distance_to(points[i + 1])
	return out


## Flat band along a polyline. y_from / y_to let a deck climb for bridge approaches.
## If `auto_width` is true, half-width is taken per point from `widths`.
func ribbon(points: PackedVector2Array, half_width: float, y_from: float, y_to: float,
		col: Color, arcs: PackedFloat32Array = PackedFloat32Array(),
		half_widths: PackedFloat32Array = PackedFloat32Array()) -> void:
	if points.size() < 2:
		return
	var n := points.size()
	var y0 := y_from
	for i in range(n - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var dir := b - a
		var l := dir.length()
		if l < 0.0001:
			continue
		var t0 := float(i) / float(n - 1)
		var t1 := float(i + 1) / float(n - 1)
		var hw0 := half_width if half_widths.is_empty() else half_widths[i]
		var hw1 := half_width if half_widths.is_empty() else half_widths[mini(i + 1, n - 1)]
		var sx := Vector2(-dir.y, dir.x) / l
		var ya := lerpf(y_from, y_to, t0)
		var yb := lerpf(y_from, y_to, t1)
		var ua := arcs[i] if i < arcs.size() else float(i) * l
		var ub := arcs[mini(i + 1, n - 1)] if i + 1 < arcs.size() else ua + l
		var base := verts.size()
		verts.append(Vector3(a.x + sx.x * hw0, ya, a.y + sx.y * hw0))
		verts.append(Vector3(b.x + sx.x * hw1, yb, b.y + sx.y * hw1))
		verts.append(Vector3(b.x - sx.x * hw1, yb, b.y - sx.y * hw1))
		verts.append(Vector3(a.x - sx.x * hw0, ya, a.y - sx.y * hw0))
		for k in 4:
			norms.append(Vector3.UP)
			cols.append(col)
		uvs.append(Vector2(ua, 0.0)); uvs.append(Vector2(ub, 0.0))
		uvs.append(Vector2(ub, 1.0)); uvs.append(Vector2(ua, 1.0))
		idx.append(base); idx.append(base + 1); idx.append(base + 2)
		idx.append(base); idx.append(base + 2); idx.append(base + 3)
		y0 = yb


## Vertical wall along one edge of a polyline: bridge fascia, embankment quays, kerb faces.
## side = +1 uses the left edge of the travel direction, -1 the right.
func skirt(points: PackedVector2Array, half_width: float, y_top: float, y_bottom: float,
		col: Color, arcs: PackedFloat32Array = PackedFloat32Array(), side: int = 1,
		half_widths: PackedFloat32Array = PackedFloat32Array()) -> void:
	if points.size() < 2:
		return
	var n := points.size()
	for i in range(n - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var dir := b - a
		var l := dir.length()
		if l < 0.0001:
			continue
		var sx := Vector2(-dir.y, dir.x) / l * float(side)
		var ua := arcs[i] if i < arcs.size() else float(i) * l
		var ub := arcs[mini(i + 1, n - 1)] if i + 1 < arcs.size() else ua + l
		var hw0 := half_width if half_widths.is_empty() else half_widths[i]
		var hw1 := half_width if half_widths.is_empty() else half_widths[mini(i + 1, n - 1)]
		var oa := sx * hw0
		var ob := sx * hw1
		var base := verts.size()
		verts.append(Vector3(a.x + oa.x, y_top, a.y + oa.y))
		verts.append(Vector3(b.x + ob.x, y_top, b.y + ob.y))
		verts.append(Vector3(b.x + ob.x, y_bottom, b.y + ob.y))
		verts.append(Vector3(a.x + oa.x, y_bottom, a.y + oa.y))
		var nrm := Vector3(sx.x, 0.0, sx.y).normalized()
		for k in 4:
			norms.append(nrm)
			cols.append(col)
		uvs.append(Vector2(ua, 0.0)); uvs.append(Vector2(ub, 0.0))
		uvs.append(Vector2(ub, y_top - y_bottom)); uvs.append(Vector2(ua, y_top - y_bottom))
		idx.append(base); idx.append(base + 1); idx.append(base + 2)
		idx.append(base); idx.append(base + 2); idx.append(base + 3)


## Closed polygon fan for plazas, pads and courtyards.
func polygon_2d(points: PackedVector2Array, y: float, col: Color) -> void:
	if points.size() < 3:
		return
	var c := Vector2.ZERO
	for p in points:
		c += p
	c /= float(points.size())
	var center := Vector3(c.x, y, c.y)
	for i in range(points.size()):
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		triangle(center, Vector3(a.x, y, a.y), Vector3(b.x, y, b.y), Vector3.UP, col)


## General quadrilateral prism on an arbitrary plot outline — the lattice is warped, so
## plots are not axis-aligned. top_scale / top_rot give setbacks and twisting towers.
func prism(corners: PackedVector2Array, y0: float, y1: float, col: Color,
		top_scale: float = 1.0, top_rot: float = 0.0, cap_bottom: bool = true) -> void:
	if corners.size() < 3:
		return
	var c := Vector2.ZERO
	for p in corners:
		c += p
	c /= float(corners.size())
	var n := corners.size()
	var bot: Array[Vector3] = []
	var top: Array[Vector3] = []
	for i in n:
		bot.append(Vector3(corners[i].x, y0, corners[i].y))
		var v: Vector2 = corners[i] - c
		if top_rot != 0.0:
			v = v.rotated(top_rot)
		var t: Vector2 = c + v * top_scale
		top.append(Vector3(t.x, y1, t.y))
	for i in n:
		var j := (i + 1) % n
		var mid: Vector2 = (corners[i] + corners[j]) * 0.5 - c
		var nrm := Vector3(mid.x, 0.0, mid.y).normalized()
		quad(bot[i], bot[j], top[j], top[i], nrm, col)
	var fc := Vector3(c.x, y1, c.y)
	for i in n:
		var j := (i + 1) % n
		triangle(fc, top[i], top[j], Vector3.UP, col)
	if cap_bottom:
		var cb := Vector3(c.x, y0, c.y)
		for i in n:
			var j := (i + 1) % n
			triangle(cb, bot[j], bot[i], Vector3.DOWN, col)


## Outline ring at a height, used for podium roof decks and parapets.
func slab(corners: PackedVector2Array, y: float, thickness: float, outset: float, col: Color) -> void:
	if corners.size() < 3:
		return
	var c := Vector2.ZERO
	for p in corners:
		c += p
	c /= float(corners.size())
	var outer := PackedVector2Array()
	for v0 in corners:
		var v: Vector2 = v0 - c
		var l := maxf(v.length(), 0.001)
		outer.append(c + v * ((l + outset) / l))
	prism(outer, y - thickness, y, col, 1.0, 0.0, true)


func quad4(c0: Vector3, c1: Vector3, c2: Vector3, c3: Vector3, col: Color) -> void:
	var nrm := (c1 - c0).cross(c3 - c0).normalized()
	quad(c0, c1, c2, c3, nrm, col)
