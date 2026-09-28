class_name Landmarks
extends Node3D
## Builds every registered landmark once at boot. Landmarks are global geometry because they
## span chunk boundaries and must never pop in/out with the streamer. The factory writes into
## shared MeshFusion buffers so the whole skyline is a handful of draw calls.

var _buildings := MeshFusion.new()
var _props := MeshFusion.new()
var _emissive := MeshFusion.new()
var _colliders: Array = []


func _ready() -> void:
	var ctx := ChunkCtx.new()
	ctx.setup(0xDEAD)
	ctx.detail = true
	# Override the fusions so the factory writes into our globals instead of per-chunk ones.
	ctx.buildings = _buildings
	ctx.props = _props
	ctx.emissive = _emissive
	for lm in CityData.LANDMARKS:
		LandmarkFactory.build(ctx, lm)
	_colliders = ctx.colliders
	_commit()


func _commit() -> void:
	if not _buildings.is_empty():
		var mi := MeshInstance3D.new()
		mi.mesh = _buildings.commit()
		mi.material_overlay = Assets.facade_mat()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.extra_cull_margin = 600.0
		add_child(mi)
	if not _props.is_empty():
		var mi2 := MeshInstance3D.new()
		mi2.mesh = _props.commit()
		mi2.material_overlay = Assets.props_mat()
		mi2.extra_cull_margin = 400.0
		add_child(mi2)
	if not _emissive.is_empty():
		var mi3 := MeshInstance3D.new()
		mi3.mesh = _emissive.commit()
		mi3.material_overlay = Assets.emissive_mat()
		mi3.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi3.extra_cull_margin = 400.0
		add_child(mi3)
	if not _colliders.is_empty():
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
		for cld in _colliders:
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(maxf(cld["s"].x, 0.6), maxf(cld["s"].y, 0.6), maxf(cld["s"].z, 0.6))
			cs.shape = shape
			cs.position = cld["c"]
			cs.rotation.y = cld["r"]
			body.add_child(cs)


func stats() -> Dictionary:
	return {"tris": _buildings.tri_count() + _props.tri_count() + _emissive.tri_count(),
		"colliders": _colliders.size()}
