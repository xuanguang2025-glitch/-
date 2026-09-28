class_name Props
extends RefCounted
## Street furniture for the decoration tool — the layer that makes a player-built block look
## inhabited rather than merely built.
##
## Every item is assembled from the same MeshFusion primitives the procedural city uses, so a
## player-placed plane tree shares a trunk and canopy generator with the ones the avenue
## builder scatter, and nothing here needs an imported asset. Colours carry a palette code in
## their alpha channel, exactly as CellProgram does, so the road/ground/facade shaders treat
## prop geometry as the same material family as the generated city.

const G := CellProgram.CODE_GROUND
const P := CellProgram.CODE_PAVE
const C := CellProgram.CODE_CONC


static func _shade(code: float, c: Color) -> Color:
	return CellProgram.col(code, c)


## The footprint marker for a player-created person: a small ring on the pavement. It is the
## only geometry the NPC tool emits, because the person themselves is drawn by the crowd
## system — a second body renderer here would be a second source of truth about what they look
## like, and it would not follow their schedule.
static func person_marker(ctx: ChunkCtx) -> void:
	var ring := _shade(P, Color(0.95, 0.78, 0.28))
	for i in 10:
		var a0 := TAU * float(i) / 10.0
		var a1 := TAU * float(i + 1) / 10.0
		var p0 := Vector2(cos(a0), sin(a0)) * 0.62
		var p1 := Vector2(cos(a1), sin(a1)) * 0.62
		var q0 := Vector2(cos(a0), sin(a0)) * 0.42
		var q1 := Vector2(cos(a1), sin(a1)) * 0.42
		ctx.streets.quad(Vector3(p0.x, 0.03, p0.y), Vector3(p1.x, 0.03, p1.y),
			Vector3(q1.x, 0.03, q1.y), Vector3(q0.x, 0.03, q0.y), Vector3.UP, ring)
	ctx.emissive.ellipsoid(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.05, 0.0)),
		Vector3(0.34, 0.02, 0.34), Color(1.0, 0.86, 0.42), 3, 8)

static func plane_tree(ctx: ChunkCtx, c: Vector2, r: float) -> void:
	var s := 0.85 + r * 0.5
	ctx.props.cylinder(Transform3D(Basis.IDENTITY, Vector3(c.x, 0.0, c.y)),
		0.22 * s, 0.14 * s, 3.4 * s, _shade(G, Color(0.26, 0.20, 0.15)), 6, false)
	var leaf := Color(0.16, 0.27, 0.12) if r < 0.55 else Color(0.25, 0.33, 0.14)
	leaf.a = CellProgram.CODE_GRASS
	var xf := Transform3D(Basis.IDENTITY, Vector3(c.x, 3.6 * s, c.y))
	ctx.props.ellipsoid(xf, Vector3(2.3 * s, 1.35 * s, 2.3 * s), leaf, 4, 7)
	ctx.props.ellipsoid(xf.translated(Vector3(1.0 * s, 0.6 * s, 0.4 * s)),
		Vector3(1.45 * s, 0.95 * s, 1.45 * s), leaf, 4, 6)
	ctx.add_box_collider(Vector3(c.x, 1.7 * s, c.y), Vector3(0.5, 3.4 * s, 0.5), 0.0)


static func bench(ctx: ChunkCtx, c: Vector2, yaw: float, r: float) -> void:
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, -yaw), Vector3(c.x, 0.0, c.y))
	var wood := _shade(P, Color(0.30, 0.20, 0.13))
	var iron := _shade(C, Color(0.13, 0.13, 0.15))
	for i in 4:
		ctx.props.box(xf.translated_local(Vector3(0.0, 0.44, -0.42 + float(i) * 0.28)),
			Vector3(1.65, 0.06, 0.20), wood)
	for i in 3:
		ctx.props.box(xf.translated_local(Vector3(0.0, 0.72 + float(i) * 0.22, -0.52)),
			Vector3(1.65, 0.18, 0.05), wood)
	for s in [-1, 1]:
		ctx.props.box(xf.translated_local(Vector3(0.74 * float(s), 0.24, -0.30)),
			Vector3(0.07, 0.48, 0.90), iron)
		ctx.props.box(xf.translated_local(Vector3(0.74 * float(s), 0.24, 0.34)),
			Vector3(0.07, 0.48, 0.90), iron)
	ctx.add_box_collider(Vector3(c.x, 0.4, c.y), Vector3(1.7, 0.8, 0.9), -yaw)


static func litter_bin(ctx: ChunkCtx, c: Vector2, yaw: float, _r: float) -> void:
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, -yaw), Vector3(c.x, 0.0, c.y))
	ctx.props.cylinder(xf, 0.30, 0.34, 0.86, _shade(C, Color(0.16, 0.19, 0.17)), 8, false)
	ctx.props.cylinder(xf.translated_local(Vector3(0.0, 0.90, 0.0)), 0.36, 0.30, 0.10,
		_shade(C, Color(0.10, 0.11, 0.12)), 8, false)
	ctx.add_box_collider(Vector3(c.x, 0.45, c.y), Vector3(0.7, 0.9, 0.7), 0.0)


## 隔离桩. Rows of these are how a Shanghai corner keeps taxis off the pavement.
static func bollard(ctx: ChunkCtx, c: Vector2, _yaw: float, _r: float) -> void:
	var xf := Transform3D(Basis.IDENTITY, Vector3(c.x, 0.0, c.y))
	ctx.props.cylinder(xf, 0.11, 0.09, 0.72, _shade(C, Color(0.72, 0.72, 0.70)), 6, false)
	ctx.emissive.cylinder(xf.translated_local(Vector3(0.0, 0.52, 0.0)), 0.10, 0.10, 0.10,
		Color(0.95, 0.86, 0.42), 6, false)


static func street_lamp(ctx: ChunkCtx, c: Vector2, yaw: float, _r: float) -> void:
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, -yaw), Vector3(c.x, 0.0, c.y))
	var steel := _shade(C, Color(0.20, 0.21, 0.22))
	ctx.props.cylinder(xf, 0.14, 0.10, 6.6, steel, 6, false)
	ctx.props.box(xf.translated_local(Vector3(0.75, 6.45, 0.0)),
		Vector3(1.6, 0.12, 0.12), steel)
	ctx.emissive.box(xf.translated_local(Vector3(1.42, 6.32, 0.0)),
		Vector3(0.62, 0.20, 0.34), Color(1.0, 0.92, 0.72))
	ctx.add_box_collider(Vector3(c.x, 3.3, c.y), Vector3(0.4, 6.6, 0.4), 0.0)


## 公交站牌 — a post, a panel, and a lit route strip.
static func stop_sign(ctx: ChunkCtx, c: Vector2, yaw: float, _r: float) -> void:
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, -yaw), Vector3(c.x, 0.0, c.y))
	var steel := _shade(C, Color(0.24, 0.26, 0.29))
	ctx.props.cylinder(xf, 0.08, 0.08, 2.9, steel, 6, false)
	ctx.props.box(xf.translated_local(Vector3(0.0, 2.30, 0.0)), Vector3(1.30, 1.05, 0.07), steel)
	ctx.emissive.box(xf.translated_local(Vector3(0.0, 2.62, 0.05)),
		Vector3(1.14, 0.16, 0.03), Color(0.20, 0.62, 0.95))
	ctx.add_box_collider(Vector3(c.x, 1.45, c.y), Vector3(0.4, 2.9, 0.4), 0.0)


## 广告灯箱 — the thing a block becomes at 20:00.
static func ad_board(ctx: ChunkCtx, c: Vector2, yaw: float, r: float) -> void:
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, -yaw), Vector3(c.x, 0.0, c.y))
	var frame := _shade(C, Color(0.17, 0.17, 0.19))
	for s in [-1, 1]:
		ctx.props.box(xf.translated_local(Vector3(1.05 * float(s), 1.10, 0.0)),
			Vector3(0.14, 2.20, 0.14), frame)
	ctx.props.box(xf.translated_local(Vector3(0.0, 2.70, 0.0)), Vector3(2.45, 1.30, 0.16), frame)
	var hue := Color(0.95, 0.72, 0.30)
	if r > 0.34:
		hue = Color(0.45, 0.75, 0.95)
	if r > 0.67:
		hue = Color(0.90, 0.45, 0.55)
	ctx.emissive.box(xf.translated_local(Vector3(0.0, 2.70, 0.10)),
		Vector3(2.22, 1.08, 0.04), hue)
	ctx.add_box_collider(Vector3(c.x, 1.1, c.y), Vector3(2.3, 2.2, 0.3), -yaw)


## 施工水马 — the red-and-white plastic barrier that every Shanghai street worksite uses.
static func barrier(ctx: ChunkCtx, c: Vector2, yaw: float, _r: float) -> void:
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, -yaw), Vector3(c.x, 0.0, c.y))
	ctx.props.box(xf.translated_local(Vector3(0.0, 0.42, 0.0)),
		Vector3(1.90, 0.84, 0.36), _shade(P, Color(0.80, 0.22, 0.16)))
	ctx.props.box(xf.translated_local(Vector3(0.0, 0.86, 0.0)),
		Vector3(1.90, 0.06, 0.38), _shade(P, Color(0.86, 0.86, 0.84)))
	ctx.add_box_collider(Vector3(c.x, 0.45, c.y), Vector3(1.9, 0.9, 0.4), -yaw)


static func parked_car(ctx: ChunkCtx, c: Vector2, yaw: float, r: float) -> void:
	CellProgram.parked_car(ctx, c, Vector2(cos(yaw + PI * 0.5), sin(yaw + PI * 0.5)), r)
	ctx.add_box_collider(Vector3(c.x, 0.7, c.y), Vector3(1.9, 1.4, 4.4), -yaw)
