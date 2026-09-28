class_name LandmarkFactory
extends RefCounted
## Procedural massing for Shanghai's signature buildings. Every shape is built from the same
## MeshFusion primitives the rest of the city uses, so landmarks share materials, LOD and
## collision with ordinary blocks. No licensed geometry — each form is an original model
## whose proportions and silhouette are *inspired by* the real structure.

const GY := 0.02


## Dispatch table: type string -> builder function. Called once per landmark at stream time.
static func build(ctx: ChunkCtx, lm: Dictionary) -> void:
	var t: String = lm["type"]
	var xf := Transform3D(Basis.IDENTITY.rotated(Vector3.UP, float(lm.get("rot", 0.0))),
		Vector3(float(lm["x"]), GY, float(lm["z"])))
	match t:
		"pearl_tower":
			_pearl_tower(ctx, xf)
		"shanghai_tower":
			_shanghai_tower(ctx, xf)
		"swfc":
			_swfc(ctx, xf)
		"jinmao":
			_jinmao(ctx, xf)
		"bund_row":
			_bund_row(ctx, xf, float(lm.get("len", 1200.0)))
		"peace_hotel":
			_peace_hotel(ctx, xf)
		"customs_house":
			_customs_house(ctx, xf)
		"museum":
			_museum(ctx, xf)
		"grand_theatre":
			_grand_theatre(ctx, xf)
		"plaza":
			_plaza(ctx, xf, float(lm.get("r", 330.0)))
		"stadium":
			_stadium(ctx, xf, float(lm.get("r", 190.0)))
		"railway_station":
			_railway_station(ctx, xf)
		"lupu_bridge", "nanpu_bridge", "yangpu_bridge", "waibaidu_bridge":
			_named_bridge(ctx, xf, t)
		_:
			_generic_landmark(ctx, xf, lm)


# --- 东方明珠 ---------------------------------------------------------------
## Three spheres on three angled columns plus an antenna mast. The most instantly
## recognisable silhouette in the Shanghai skyline.
static func _pearl_tower(ctx: ChunkCtx, xf: Transform3D) -> void:
	var steel := Color(0.55, 0.56, 0.60)
	var sphere_col := Color(0.72, 0.18, 0.22)
	var glass := Color(0.28, 0.32, 0.40)
	# Base platform.
	ctx.buildings.box(xf, Vector3(60.0, 12.0, 60.0), steel, 0.88)
	_add_collider(ctx, xf, Vector3(60.0, 12.0, 60.0))
	# Three legs fanning out from the base to the lower sphere.
	for i in 3:
		var a := TAU * float(i) / 3.0
		var foot := xf * Vector3(cos(a) * 24.0, 0.0, sin(a) * 24.0)
		var top := xf * Vector3(cos(a) * 8.0, 95.0, sin(a) * 8.0)
		var mid := (foot + top) * 0.5
		var dir := (top - foot).normalized()
		var len := foot.distance_to(top)
		var leg_xf := Transform3D(Basis.IDENTITY.looking_at(dir, Vector3.UP), mid)
		ctx.buildings.cylinder(leg_xf, 3.2, 2.6, len, steel, 8, false)
	# Lower observation sphere.
	ctx.buildings.ellipsoid(xf.translated(Vector3(0, 95, 0)),
		Vector3(25.0, 22.0, 25.0), sphere_col, 10, 14)
	_add_collider_sphere(ctx, xf * Vector3(0, 95, 0), 25.0)
	# Middle column.
	ctx.buildings.cylinder(xf.translated(Vector3(0, 117, 0)), 5.5, 4.8, 115.0, steel, 10, false)
	# Upper observation sphere.
	ctx.buildings.ellipsoid(xf.translated(Vector3(0, 232, 0)),
		Vector3(18.0, 16.0, 18.0), sphere_col, 9, 12)
	_add_collider_sphere(ctx, xf * Vector3(0, 232, 0), 18.0)
	# Top module + antenna.
	ctx.buildings.cylinder(xf.translated(Vector3(0, 248, 0)), 4.2, 3.0, 42.0, glass, 8, false)
	ctx.buildings.ellipsoid(xf.translated(Vector3(0, 290, 0)),
		Vector3(5.5, 5.0, 5.5), sphere_col, 6, 8)
	ctx.buildings.cylinder(xf.translated(Vector3(0, 295, 0)), 1.2, 0.3, 62.0, steel, 6, false)
	# Aviation warning light.
	ctx.emissive.add_primitive(Assets.sphere(1.6, 8),
		Transform3D(Basis.IDENTITY, xf * Vector3(0, 358, 0)), Color(1.0, 0.12, 0.08))
	# Signature pink/red sphere glow — the Pearl's night identity.
	for sy in [95.0, 232.0]:
		var sr := 26.0 if sy < 150.0 else 19.0
		ctx.emissive.ellipsoid(xf.translated(Vector3(0, sy, 0)),
			Vector3(sr, sr * 0.88, sr), Color(0.95, 0.22, 0.35), 8, 10)


# --- 上海中心大厦 ------------------------------------------------------------
## 632 m twisted taper. Built as stacked rotated storeys so the twist is geometric, not
## just a texture trick.
static func _shanghai_tower(ctx: ChunkCtx, xf: Transform3D) -> void:
	var glass := Color(0.30, 0.38, 0.48)
	glass.a = 1.0	# LED media-facade flag
	var crown := Color(0.42, 0.48, 0.56)
	# Podium.
	ctx.buildings.box(xf, Vector3(72.0, 18.0, 72.0), Color(0.44, 0.46, 0.50), 0.92)
	_add_collider(ctx, xf, Vector3(72.0, 18.0, 72.0))
	# Twisted shaft: 18 segments, cumulative 120° rotation, linear taper 1.0 → 0.38.
	var segs := 18
	var seg_h := 614.0 / float(segs)
	var cur := xf.translated(Vector3(0, 18, 0))
	for i in segs:
		var t := float(i) / float(segs)
		var sc := 1.0 - t * 0.62
		var w := 52.0 * sc
		var rot := deg_to_rad(120.0) * t
		var seg_xf := cur.rotated_local(Vector3.UP, rot)
		ctx.buildings.box(seg_xf, Vector3(w, seg_h, w), glass, 1.0)
		cur = cur.translated(Vector3(0, seg_h, 0))
	_add_collider(ctx, xf.translated(Vector3(0, 18 + 307, 0)), Vector3(52.0, 614.0, 52.0))
	# Crown lantern + spire.
	ctx.buildings.box(cur, Vector3(18.0, 38.0, 18.0), crown, 0.55)
	ctx.buildings.cylinder(cur.translated(Vector3(0, 38, 0)), 2.8, 0.4, 80.0,
		Color(0.62, 0.64, 0.68), 6, false)
	ctx.emissive.add_primitive(Assets.sphere(1.8, 8),
		Transform3D(Basis.IDENTITY, cur * Vector3(0, 120, 0)), Color(1.0, 0.12, 0.08))
	# Blue LED crown band — Shanghai Tower's night signature.
	ctx.emissive.box(cur.translated(Vector3(0, -4, 0)),
		Vector3(20.0, 6.0, 20.0), Color(0.15, 0.45, 0.95))
	# Vertical LED strips along the twist seams.
	for s in 4:
		var a := TAU * float(s) / 4.0
		var sx := cos(a) * 26.0
		var sz := sin(a) * 26.0
		ctx.emissive.box(xf.translated(Vector3(sx, 200, sz)),
			Vector3(1.2, 380.0, 1.2), Color(0.10, 0.35, 0.85))


# --- 环球金融中心 SWFC -------------------------------------------------------
## Trapezoidal tower with the iconic bottle-opener aperture near the top.
static func _swfc(ctx: ChunkCtx, xf: Transform3D) -> void:
	var glass := Color(0.26, 0.30, 0.38)
	var frame := Color(0.40, 0.42, 0.46)
	# Main tapered shaft.
	ctx.buildings.box(xf, Vector3(52.0, 492.0, 52.0), glass, 0.58)
	_add_collider(ctx, xf.translated(Vector3(0, 246, 0)), Vector3(52.0, 492.0, 52.0))
	# The aperture: two horizontal beams framing a void near the top. In practice we draw
	# the beams; the void is the absence of geometry between them.
	var ap_y := 430.0
	var ap_h := 42.0
	var beam := 8.0
	ctx.buildings.box(xf.translated(Vector3(0, ap_y, 0)),
		Vector3(54.0, beam, 54.0), frame, 1.0)
	ctx.buildings.box(xf.translated(Vector3(0, ap_y + ap_h, 0)),
		Vector3(54.0, beam, 54.0), frame, 1.0)
	# Side fins that give the trapezoid its edge.
	for s in [-1, 1]:
		var fin_xf := xf.translated(Vector3(28.0 * float(s), 0, 0))
		ctx.buildings.box(fin_xf, Vector3(4.0, 460.0, 54.0), frame, 0.62)
	# Spire.
	ctx.buildings.cylinder(xf.translated(Vector3(0, 492, 0)), 2.4, 0.4, 52.0,
		Color(0.60, 0.62, 0.66), 6, false)
	# Aperture frame glow — the bottle-opener's night signature.
	ctx.emissive.box(xf.translated(Vector3(0, ap_y + ap_h * 0.5, 0)),
		Vector3(56.0, ap_h + 2.0, 56.0), Color(0.85, 0.88, 0.95))


# --- 金茂大厦 ----------------------------------------------------------------
## Pagoda-tiered setbacks: 13 distinct steps that shrink as they rise. The most ornate of
## the Lujiazui trio.
static func _jinmao(ctx: ChunkCtx, xf: Transform3D) -> void:
	var gold := Color(0.58, 0.52, 0.38)
	var dark := Color(0.32, 0.30, 0.26)
	# 13 setback tiers. Each tier shrinks ~6 % and rotates slightly.
	var tiers := [
		[56.0, 52.0], [52.0, 48.0], [48.0, 44.0], [44.0, 40.0],
		[40.0, 36.0], [36.0, 32.0], [32.0, 28.0], [28.0, 25.0],
		[25.0, 22.0], [22.0, 19.0], [19.0, 16.0], [16.0, 13.0], [13.0, 10.0],
	]
	var y := 0.0
	var total := 421.0
	var tier_h := total / float(tiers.size())
	for i in tiers.size():
		var sz: Array = tiers[i]
		var w: float = sz[0]
		var col := gold if i % 2 == 0 else dark
		var t_xf := xf.translated(Vector3(0, y, 0))
		ctx.buildings.box(t_xf, Vector3(w, tier_h, w), col, float(sz[1]) / maxf(w, 1.0))
		y += tier_h
	_add_collider(ctx, xf.translated(Vector3(0, total * 0.5, 0)), Vector3(56.0, total, 56.0))
	# Crown spire.
	ctx.buildings.cylinder(xf.translated(Vector3(0, total, 0)), 3.0, 0.5, 62.0,
		Color(0.62, 0.58, 0.44), 8, false)
	# Warm gold tier bands — Jinmao's pagoda glow at night.
	for i in tiers.size():
		var ty := float(i) * tier_h + tier_h * 0.85
		var tw: float = tiers[i][0]
		ctx.emissive.box(xf.translated(Vector3(0, ty, 0)),
			Vector3(tw + 1.5, 1.8, tw + 1.5), Color(0.95, 0.72, 0.32))


# --- 外滩万国建筑群 -----------------------------------------------------------
## A continuous band of neoclassical facades along the west bank. Individual buildings vary
## in height and cornice detail but share the warm stone palette.
static func _bund_row(ctx: ChunkCtx, xf: Transform3D, length: float) -> void:
	var stone := Color(0.68, 0.62, 0.52)
	var dark_stone := Color(0.52, 0.46, 0.38)
	var n := clampi(int(length / 38.0), 8, 36)
	var pitch := length / float(n)
	for i in n:
		var x_off := -length * 0.5 + (float(i) + 0.5) * pitch
		var h := 18.0 + GameGlobals.hash2(i, 0, 801) * 22.0
		var w := pitch * (0.88 + GameGlobals.hash2(i, 1, 802) * 0.10)
		var d := 14.0 + GameGlobals.hash2(i, 2, 803) * 8.0
		var col := stone if GameGlobals.hash2(i, 3, 804) > 0.35 else dark_stone
		var b_xf := xf.translated(Vector3(x_off, 0, 0))
		ctx.buildings.box(b_xf, Vector3(w, h, d), col, 1.0)
		_add_collider(ctx, b_xf, Vector3(w, h, d))
		# Cornice band at the top.
		ctx.props.box(b_xf.translated(Vector3(0, h, 0)),
			Vector3(w + 0.8, 1.2, d + 0.8), Color(0.60, 0.56, 0.48))
		# Ground-floor arcade.
		ctx.emissive.box(b_xf.translated(Vector3(0, 1.8, d * 0.5 + 0.1)),
			Vector3(w * 0.92, 3.6, 0.3), Color(0.95, 0.78, 0.48))
		# Facade uplighting — the warm wash that defines the Bund at night.
		ctx.emissive.box(b_xf.translated(Vector3(0, h * 0.5, d * 0.5 + 0.2)),
			Vector3(w * 0.88, h * 0.7, 0.15), Color(0.92, 0.78, 0.52))


# --- 和平饭店 ----------------------------------------------------------------
## Art Deco pyramid-roofed hotel at the north end of the Bund.
static func _peace_hotel(ctx: ChunkCtx, xf: Transform3D) -> void:
	var body := Color(0.42, 0.38, 0.32)
	var roof := Color(0.18, 0.38, 0.22)
	ctx.buildings.box(xf, Vector3(38.0, 48.0, 28.0), body, 1.0)
	_add_collider(ctx, xf.translated(Vector3(0, 24, 0)), Vector3(38.0, 48.0, 28.0))
	# Green copper pyramid.
	var pyr := PackedVector2Array([
		Vector2(-19, -14), Vector2(19, -14), Vector2(19, 14), Vector2(-19, 14)])
	ctx.props.prism(pyr, 48.0, 62.0, roof, 0.05)


# --- 海关大楼 ----------------------------------------------------------------
## Clock tower on the Bund, the visual anchor of the waterfront.
static func _customs_house(ctx: ChunkCtx, xf: Transform3D) -> void:
	var stone := Color(0.62, 0.58, 0.50)
	ctx.buildings.box(xf, Vector3(42.0, 36.0, 30.0), stone, 1.0)
	_add_collider(ctx, xf.translated(Vector3(0, 18, 0)), Vector3(42.0, 36.0, 30.0))
	# Tower.
	ctx.buildings.box(xf.translated(Vector3(0, 36, 0)), Vector3(14.0, 42.0, 14.0), stone, 0.82)
	# Clock face (emissive disc).
	ctx.emissive.add_primitive(Assets.cyl(4.5, 0.4, 16),
		xf.translated(Vector3(0, 62, 7.2)).rotated_local(Vector3.RIGHT, PI * 0.5),
		Color(1.0, 0.92, 0.72))
	# Cupola.
	ctx.props.ellipsoid(xf.translated(Vector3(0, 78, 0)),
		Vector3(6.0, 5.0, 6.0), Color(0.28, 0.32, 0.28), 6, 8)


# --- 上海博物馆 ---------------------------------------------------------------
## Round base + square top (天圆地方).
static func _museum(ctx: ChunkCtx, xf: Transform3D) -> void:
	var stone := Color(0.62, 0.60, 0.56)
	ctx.buildings.cylinder(xf, 48.0, 48.0, 18.0, stone, 24, true)
	_add_collider(ctx, xf.translated(Vector3(0, 9, 0)), Vector3(96.0, 18.0, 96.0))
	ctx.buildings.box(xf.translated(Vector3(0, 18, 0)), Vector3(62.0, 22.0, 62.0), stone, 0.88)
	_add_collider(ctx, xf.translated(Vector3(0, 29, 0)), Vector3(62.0, 22.0, 62.0))


# --- 上海大剧院 ---------------------------------------------------------------
## Inverted arc shell — approximated as a lofted slab.
static func _grand_theatre(ctx: ChunkCtx, xf: Transform3D) -> void:
	var white := Color(0.82, 0.82, 0.84)
	ctx.buildings.loft(xf, Vector2(55, 40), Vector2(62, 48), 0.0, 28.0, white)
	_add_collider(ctx, xf.translated(Vector3(0, 14, 0)), Vector3(120.0, 28.0, 90.0))
	# Glass curtain wall on the front face.
	ctx.emissive.box(xf.translated(Vector3(0, 14, 42)),
		Vector3(100.0, 24.0, 1.0), Color(0.55, 0.70, 0.88))


# --- 人民广场 -----------------------------------------------------------------
static func _plaza(ctx: ChunkCtx, xf: Transform3D, r: float) -> void:
	var pave := Color(0.55, 0.53, 0.50)
	pave.a = 3.0
	var pts := PackedVector2Array()
	var n := 24
	for i in n:
		var th := TAU * float(i) / float(n)
		pts.append(Vector2(cos(th) * r, sin(th) * r))
	ctx.plates.polygon_2d(pts, 0.08, pave)


# --- 上海体育场 ---------------------------------------------------------------
## Torus bowl.
static func _stadium(ctx: ChunkCtx, xf: Transform3D, r: float) -> void:
	var conc := Color(0.58, 0.57, 0.55)
	ctx.buildings.cylinder(xf, r, r * 0.82, 42.0, conc, 32, false)
	_add_collider(ctx, xf.translated(Vector3(0, 21, 0)), Vector3(r * 2, 42.0, r * 2))
	# Inner void.
	ctx.buildings.cylinder(xf.translated(Vector3(0, 6, 0)), r * 0.72, r * 0.72, 38.0,
		Color(0.18, 0.28, 0.18), 24, false)


# --- 上海火车站 ---------------------------------------------------------------
static func _railway_station(ctx: ChunkCtx, xf: Transform3D) -> void:
	var conc := Color(0.56, 0.55, 0.53)
	var glass := Color(0.32, 0.38, 0.46)
	ctx.buildings.box(xf, Vector3(180.0, 22.0, 80.0), conc, 1.0)
	_add_collider(ctx, xf.translated(Vector3(0, 11, 0)), Vector3(180.0, 22.0, 80.0))
	# Central clock tower.
	ctx.buildings.box(xf.translated(Vector3(0, 22, 0)), Vector3(32.0, 38.0, 32.0), conc, 0.78)
	# Glass canopy over the platforms.
	ctx.props.box(xf.translated(Vector3(0, 18, -50)),
		Vector3(160.0, 1.0, 40.0), glass)


# --- Named bridges ----------------------------------------------------------
## Simplified cable-stayed / arch forms for the four Huangpu crossings. Real geometry would
## need hundreds of cables; this gives the right silhouette at skyline distance.
static func _named_bridge(ctx: ChunkCtx, xf: Transform3D, name: String) -> void:
	var steel := Color(0.52, 0.54, 0.58)
	var deck_col := Color(0.38, 0.38, 0.40)
	var span := 420.0
	var deck_w := 28.0
	var deck_y := 14.0
	match name:
		"nanpu_bridge":
			span = 423.0
			deck_y = 18.0
		"yangpu_bridge":
			span = 602.0
			deck_y = 20.0
		"lupu_bridge":
			span = 550.0
			deck_y = 16.0
		"waibaidu_bridge":
			span = 106.0
			deck_w = 18.0
			deck_y = 8.0
	# Deck.
	ctx.buildings.box(xf.translated(Vector3(0, deck_y, 0)),
		Vector3(span, 2.4, deck_w), deck_col, 1.0)
	_add_collider(ctx, xf.translated(Vector3(0, deck_y, 0)), Vector3(span, 2.4, deck_w))
	if name == "lupu_bridge":
		# Arch.
		var n := 16
		for i in range(n):
			var t0 := float(i) / float(n)
			var t1 := float(i + 1) / float(n)
			var x0 := (t0 - 0.5) * span
			var x1 := (t1 - 0.5) * span
			var y0 := deck_y + sin(t0 * PI) * 80.0
			var y1 := deck_y + sin(t1 * PI) * 80.0
			var p0 := xf * Vector3(x0, y0, 0)
			var p1 := xf * Vector3(x1, y1, 0)
			var mid := (p0 + p1) * 0.5
			var dir := (p1 - p0).normalized()
			var len := p0.distance_to(p1)
			var seg_xf := Transform3D(Basis.IDENTITY.looking_at(dir, Vector3.UP), mid)
			ctx.props.cylinder(seg_xf, 2.2, 2.2, len, steel, 6, false)
	else:
		# Cable-stayed pylons.
		var tower_h := 80.0 if name != "waibaidu_bridge" else 28.0
		for s in [-1, 1]:
			var tx := float(s) * span * 0.28
			ctx.buildings.box(xf.translated(Vector3(tx, 0, 0)),
				Vector3(6.0, tower_h + deck_y, 6.0), steel, 0.72)
			# Stay cables as thin diagonal boxes.
			var cables := 6
			for c in cables:
				var frac := float(c + 1) / float(cables + 1)
				var cx := tx + float(s) * frac * span * 0.22
				var cy := deck_y + frac * tower_h
				var p0 := xf * Vector3(tx, tower_h + deck_y - 4.0, 0)
				var p1 := xf * Vector3(cx, cy, 0)
				var mid2 := (p0 + p1) * 0.5
				var dir2 := (p1 - p0).normalized()
				var len2 := p0.distance_to(p1)
				var cable_xf := Transform3D(Basis.IDENTITY.looking_at(dir2, Vector3.UP), mid2)
				ctx.props.cylinder(cable_xf, 0.18, 0.18, len2, steel, 4, false)


# --- Generic fallback -------------------------------------------------------
static func _generic_landmark(ctx: ChunkCtx, xf: Transform3D, lm: Dictionary) -> void:
	var style: String = lm.get("style", "modern_mix")
	var h: float = float(lm.get("h", 60.0))
	var w: float = float(lm.get("w", 40.0))
	var col := Assets.tint_for(style, GameGlobals.hash2(int(lm["x"]), int(lm["z"]), 901))
	ctx.buildings.box(xf, Vector3(w, h, w), col, 0.82)
	_add_collider(ctx, xf.translated(Vector3(0, h * 0.5, 0)), Vector3(w, h, w))


# --- Helpers ----------------------------------------------------------------
static func _add_collider(ctx: ChunkCtx, xf: Transform3D, size: Vector3) -> void:
	ctx.add_box_collider(xf.origin + Vector3(0, size.y * 0.5, 0), size, xf.basis.get_euler().y)


static func _add_collider_sphere(ctx: ChunkCtx, center: Vector3, r: float) -> void:
	# Approximate sphere colliders with a box; physics doesn't care about the exact shape
	# for static scenery and boxes are cheaper to test.
	ctx.add_box_collider(center, Vector3(r * 1.6, r * 1.6, r * 1.6))
