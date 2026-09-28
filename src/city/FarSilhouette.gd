class_name FarSilhouette
extends Node3D
## Coarse city volume standing in for everything outside the streamed chunk ring, which is
## what keeps the skyline continuous when you look at Lujiazui from across the river.
##
## Godot's visibility ranges only cull objects *beyond* a distance, so each tile is toggled
## by script: near tiles are hidden because real chunks are loaded under them.

const TILE := 1000.0
const CELL := 178.0
const HIDE_HYSTERESIS := 260.0

var threshold := 1700.0
var _tiles: Array = []
var _focus := Vector3.ZERO


func _ready() -> void:
	_build_tiles()


func set_focus(p: Vector3) -> void:
	_focus = p


func apply_quality(c: Dictionary) -> void:
	threshold = float(c["stream_radius"]) * GameGlobals.CHUNK_SIZE * 0.98


func _build_tiles() -> void:
	var half := GameGlobals.WORLD_HALF
	var buckets: Dictionary = {}
	var p := Vector2(-half, -half)
	while p.y < half:
		p.x = -half
		while p.x < half:
			if not CityData.blocks_building(p, 0.0):
				var gap := CityData.major_gap(p)
				if gap > 12.0:
					var hr := CityData.height_range_at(p)
					var inten := CityData.intensity_at(p)
					var h: float = lerpf(hr.x, hr.y, clampf(0.30 + inten * 0.72, 0.0, 1.0))
					if h > 7.0:
						var key := Vector2i(int(floor(p.x / TILE)), int(floor(p.y / TILE)))
						if not buckets.has(key):
							buckets[key] = MeshFusion.new()
						var style := CityData.district_style(p)
						var r := GameGlobals.hash2(int(p.x), int(p.y), 77)
						var tint := Assets.tint_for(style, r)
						var w := CELL * (0.42 + 0.30 * r)
						var xf := Transform3D(Basis.IDENTITY, Vector3(p.x - w * 0.5, 0.0, p.y - w * 0.5))
						(buckets[key] as MeshFusion).box(xf, Vector3(w, h * (0.55 + 0.45 * inten), w), tint, 0.9)
			p.x += CELL
		p.y += CELL
	for key in buckets.keys():
		var k: Vector2i = key
		var fusion: MeshFusion = buckets[key]
		if fusion.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = fusion.commit()
		mi.material_overlay = Assets.facade_mat()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 900.0
		add_child(mi)
		_tiles.append({"mi": mi, "c": Vector2((k.x + 0.5) * TILE, (k.y + 0.5) * TILE)})
	visible = true


func _process(_dt: float) -> void:
	for t in _tiles:
		var mi: MeshInstance3D = t["mi"]
		var d := Vector2(_focus.x - t["c"].x, _focus.z - t["c"].y).length()
		var want := d > threshold + (HIDE_HYSTERESIS if mi.visible else -HIDE_HYSTERESIS)
		if want != mi.visible:
			mi.visible = want


func tile_count() -> int:
	return _tiles.size()


func tri_total() -> int:
	var n := 0
	for t in _tiles:
		var m: ArrayMesh = (t["mi"] as MeshInstance3D).mesh
		if m != null and m.get_surface_count() > 0:
			n += m.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3
	return n
