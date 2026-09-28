class_name WaterBodies
extends Node3D
## Huangpu and Suzhou Creek as one global surface each. They are not chunked: a river is a
## single continuous polyline, and splitting it across streaming boundaries would seam.
##
## The drawn riverbed sits at -14 while the world's collision plane is flat at y=0, which
## is physically wrong but cheap. The 防汛墙 quay wall is what reconciles the two: it puts
## a vertical concrete face exactly where the player would otherwise see through the floor.

const WATER_Y := -0.55
const BED_Y := -14.0
const QUAY_TOP := 0.62


func _ready() -> void:
	_body(CityData.huangpu_xz, CityData.huangpu_hw, true)
	_body(CityData.creek_xz, CityData.creek_hw, false)
	_bund_promenade()


func _body(poly: PackedVector2Array, hw: PackedFloat32Array, walled: bool) -> void:
	if poly.size() < 2:
		return
	var arcs := MeshFusion.arc_lengths(poly)
	var widened := PackedFloat32Array()
	var inner := PackedFloat32Array()
	for w in hw:
		widened.append(w + 7.0)
		inner.append(maxf(w - 1.2, 1.0))

	var tint := Color(0.06, 0.09, 0.09)
	var wf := MeshFusion.new()
	wf.ribbon(poly, 200.0, WATER_Y, WATER_Y, tint, arcs, widened)
	var wmi := MeshInstance3D.new()
	wmi.mesh = wf.commit()
	wmi.material_overlay = Assets.water_mat()
	wmi.extra_cull_margin = 400.0
	add_child(wmi)

	if not walled:
		return
	var quay := Color(0.40, 0.395, 0.385)
	quay.a = 4.0
	var cap := Color(0.52, 0.515, 0.50)
	cap.a = 3.0
	var qf := MeshFusion.new()
	qf.skirt(poly, 0.0, QUAY_TOP, BED_Y, quay, arcs, 1, inner)
	qf.skirt(poly, 0.0, QUAY_TOP, BED_Y, quay, arcs, -1, inner)
	qf.ribbon(poly, 0.0, QUAY_TOP + 0.08, QUAY_TOP + 0.08, cap, arcs, inner)
	var qmi := MeshInstance3D.new()
	qmi.mesh = qf.commit()
	qmi.material_overlay = Assets.ground_mat()
	qmi.extra_cull_margin = 400.0
	add_child(qmi)


## 外滩观景平台: the raised promenade along the west bank of the Bund reach, plus the
## lower service road on the Pudong side.
func _bund_promenade() -> void:
	var poly := CityData.huangpu_xz
	var hw := CityData.huangpu_hw
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var n := poly.size()
	for i in n:
		var p: Vector2 = poly[i]
		# Only along the Bund reach; elsewhere the natural quay stays.
		if p.y < -1050.0 or p.y > 2150.0 or absf(p.x - 1530.0) > 420.0:
			continue
		var a: Vector2 = poly[mini(maxi(i - 1, 0), n - 1)]
		var b: Vector2 = poly[mini(i + 1, n - 1)]
		var dir: Vector2 = b - a
		if dir.length_squared() < 0.0001:
			continue
		dir = dir.normalized()
		var side := Vector2(-dir.y, dir.x)
		var w: float = hw[i]
		left.append(p - side * (w - 14.0))
		right.append(p + side * (w - 6.0))
	if left.size() < 2:
		return
	var deck := Color(0.52, 0.50, 0.46)
	deck.a = 3.0
	var f := MeshFusion.new()
	f.ribbon(left, 12.0, QUAY_TOP + 0.14, QUAY_TOP + 0.14, deck, MeshFusion.arc_lengths(left))
	f.skirt(left, 12.0, QUAY_TOP + 0.14, 0.0, deck, MeshFusion.arc_lengths(left), -1)
	var mi := MeshInstance3D.new()
	mi.mesh = f.commit()
	mi.material_overlay = Assets.ground_mat()
	mi.extra_cull_margin = 200.0
	add_child(mi)
