class_name WorldStreamer
extends Node3D
## Streaming loader — the World Partition equivalent. Chunks are built on a per-frame time
## budget so approach never hitches, collision is promoted only near the avatar, and the
## unloaded distance is covered by coarse HLOD-style silhouette tiles.

const BUDGET_MS := 7.0
const COLLIDE_RING := 2
## The first pass streams a small core so the street the player wakes on is complete within
## a second, then widens to the quality tier's radius one ring at a time.
const RAMP_START := 4
const RAMP_SECONDS := 1.2

var origin_of_interest: Vector2 = Vector2.ZERO
var stream_radius := 6
var _radius_now := RAMP_START
var _ramp_t := 0.0
var collide_ring := COLLIDE_RING
var lod_bias := 1.0

var _alive: Dictionary = {}			# Vector2i -> {node, ring, ctx}
var _pending: Array = []
var _camera_pos: Vector3 = Vector3.ZERO
var _built: int = 0
var _freed: int = 0
var _requeues: int = 0
var _origin_jumps: int = 0
var _tick_us: int = 0

@export var preview_chunk: Vector2i = Vector2i(5, 1)
@export var show_preview_only: bool = false


func _ready() -> void:
	add_to_group("streamer")
	top_level = false


func apply_quality(c: Dictionary) -> void:
	stream_radius = int(c["stream_radius"])
	lod_bias = float(c["lod_bias"])
	_radius_now = mini(_radius_now, stream_radius)
	_requeue()


func set_origin(p: Vector2) -> void:
	if CityData.chunk_of(p) != CityData.chunk_of(origin_of_interest):
		_origin_jumps += 1
	origin_of_interest = p
	_requeue()


func set_camera_pos(p: Vector3) -> void:
	_camera_pos = p


func _ring_of(c: Vector2i) -> int:
	var half := GameGlobals.CHUNK_SIZE * 0.5
	var d := Vector2(c.x * GameGlobals.CHUNK_SIZE - origin_of_interest.x,
		c.y * GameGlobals.CHUNK_SIZE - origin_of_interest.y)
	return int(maxf(absf(d.x), absf(d.y)) / GameGlobals.CHUNK_SIZE)


func _wanted() -> Array:
	var out: Array = []
	var r := _radius_now
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var c := CityData.chunk_of(origin_of_interest) + Vector2i(dx, dz)
			if not CityData.in_bounds(c):
				continue
			var ring := maxi(absi(dx), absi(dz))
			if ring > r:
				continue
			out.append({"c": c, "ring": ring})
	if show_preview_only:
		out = [{"c": preview_chunk, "ring": 0}]
	out.sort_custom(func(a, b): return a["ring"] < b["ring"])
	return out


var _wanted_n := 0


func _requeue() -> void:
	var w := _wanted()
	_wanted_n = w.size()
	_requeues += 1
	_pending = w


func _process(delta: float) -> void:
	if _radius_now < stream_radius:
		_ramp_t += delta
		if _ramp_t >= RAMP_SECONDS:
			_ramp_t = 0.0
			_radius_now += 1
			_requeue()
	var t0 := Time.get_ticks_usec()
	while not _pending.is_empty():
		var item: Dictionary = _pending.pop_front()
		var c: Vector2i = item["c"]
		var ring: int = item["ring"]
		if _alive.has(c):
			continue
		var detail := ring <= maxi(2, int(2 * lod_bias))
		_build(c, ring, detail)
		_built += 1
		if Time.get_ticks_usec() - t0 > int(BUDGET_MS * 1000.0):
			break
	# Drop what fell out of range.
	var max_ring := stream_radius + GameGlobals.UNLOAD_PAD
	var stale: Array = []
	for k in _alive.keys():
		var e: Dictionary = _alive[k]
		if _ring_of(k) > max_ring:
			stale.append(k)
	for k in stale:
		var e2: Dictionary = _alive[k]
		(e2["node"] as Node).queue_free()
		_alive.erase(k)
		_freed += 1
	_tick_us = int(Time.get_ticks_usec() - t0)


func desired_count() -> int:
	return _wanted().size()


func _build(c: Vector2i, ring: int, detail: bool) -> void:
	var ctx := ChunkBuilder.build(c, detail)
	var node := Node3D.new()
	node.name = "C%d_%d" % [c.x, c.y]
	add_child(node)
	# ChunkBuilder emits absolute world coordinates, so the chunk node must stay at the
	# origin. Offsetting it by the chunk centre displaced every rendered chunk by
	# chunk_index * 250 m while collision, computed with to_local, stayed correct — the
	# player then walked on invisible streets with the buildings a kilometre away.

	_instance(node, ctx.plates, Assets.ground_mat(), 0.0)
	_instance(node, ctx.streets, Assets.road_mat(2, true, 12.5), 0.0)
	var bmat := _instance(node, ctx.buildings, Assets.facade_mat(), 0.0)
	if bmat != null:
		bmat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_instance(node, ctx.props, Assets.props_mat(), 0.0)
	var em := _instance(node, ctx.emissive, Assets.emissive_mat(), 0.0)
	if em != null:
		em.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	if ring <= collide_ring:
		_collide(node, ctx)
	_alive[c] = {"node": node, "ring": ring, "tris": ctx.totals(), "ctx": ctx}


## True where the generated city already has a building. Answers from the occupancy bitmap
## each chunk writes while emitting, so the creation tools and any AI generator get the same
## answer without walking every tower. Unloaded ground reports false: nothing blocks it yet.
func is_occupied(p: Vector2) -> bool:
	var c := CityData.chunk_of(p)
	var e: Dictionary = _alive.get(c, {})
	if e.is_empty():
		return false
	var ctx: ChunkCtx = e["ctx"]
	if ctx.ground_n == 0 or ctx.occupied.is_empty():
		return false
	var i := int(floor((p.x - ctx.ground_min.x) / ctx.ground_step))
	var j := int(floor((p.y - ctx.ground_min.y) / ctx.ground_step))
	if i < 0 or j < 0 or i >= ctx.ground_n or j >= ctx.ground_n:
		return false
	return ctx.occupied[j * ctx.ground_n + i] != 0


func _instance(parent: Node, fusion: MeshFusion, mat: Material, _y: float) -> MeshInstance3D:
	if fusion.is_empty():
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = fusion.commit()
	mi.material_overlay = mat
	mi.extra_cull_margin = 12.0
	parent.add_child(mi)
	# Distant surfaces cross-fade out; the silhouette tiles stand in for them.
	var far := float(stream_radius) * GameGlobals.CHUNK_SIZE * 1.05
	mi.visibility_range_end = far
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	return mi


func _collide(parent: Node, ctx: ChunkCtx) -> void:
	if ctx.colliders.is_empty():
		return
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)
	for cld in ctx.colliders:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(maxf(cld["s"].x, 0.6), maxf(cld["s"].y, 0.6), maxf(cld["s"].z, 0.6))
		cs.shape = shape
		cs.position = parent.to_local(cld["c"])
		cs.rotation.y = cld["r"]
		body.add_child(cs)


func stats() -> Dictionary:
	var tris := 0
	for k in _alive.keys():
		tris += _alive[k]["tris"]
	return {"alive": _alive.size(), "pending": _pending.size(), "tris": tris,
		"build_us": _tick_us, "built_total": _built, "wanted": _wanted_n,
		"freed": _freed, "requeues": _requeues, "jumps": _origin_jumps}
