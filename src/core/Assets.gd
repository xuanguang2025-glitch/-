class_name Assets
extends RefCounted
## Runtime-generated materials, textures and primitive meshes.
## Nothing here is a binary asset: the whole look is procedural, which keeps the repo
## free of unlicensed content and lets weather/time drive every surface from one place.

static var _cache: Dictionary = {}
static var _road_mats: Dictionary = {}
static var _env_mats: Array = []


static func _peek(key: String) -> Object:
	return _cache.get(key)


static func _put(key: String, val: Object) -> Object:
	_cache[key] = val
	return val


# --- Textures ---------------------------------------------------------------
static func noise() -> NoiseTexture2D:
	var k := "tex_noise"
	if _cache.has(k):
		return _cache[k]
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.frequency = 0.055
	fn.fractal_octaves = 4
	fn.fractal_gain = 0.55
	fn.seed = 1337
	var t := NoiseTexture2D.new()
	t.noise = fn
	t.width = 512
	t.height = 512
	t.seamless = true
	t.as_normal_map = false
	return _put(k, t) as NoiseTexture2D


static func noise_fine() -> NoiseTexture2D:
	var k := "tex_noise_fine"
	if _cache.has(k):
		return _cache[k]
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_PERLIN
	fn.frequency = 0.32
	fn.fractal_octaves = 3
	fn.seed = 991
	var t := NoiseTexture2D.new()
	t.noise = fn
	t.width = 256
	t.height = 256
	t.seamless = true
	return _put(k, t) as NoiseTexture2D


# --- Shader materials -------------------------------------------------------
static func facade_mat() -> ShaderMaterial:
	var k := "m_facade"
	if _cache.has(k):
		return _cache[k]
	var m := ShaderMaterial.new()
	m.shader = load("res://src/shaders/facade.gdshader")
	m.set_shader_parameter("noise_tex", noise())
	m.set_shader_parameter("night", 0.0)
	m.set_shader_parameter("wetness", 0.0)
	_env_mats.append(m)
	return _put(k, m) as ShaderMaterial


static func ground_mat() -> ShaderMaterial:
	var k := "m_ground"
	if _cache.has(k):
		return _cache[k]
	var m := ShaderMaterial.new()
	m.shader = load("res://src/shaders/ground.gdshader")
	m.set_shader_parameter("noise_tex", noise())
	m.set_shader_parameter("night", 0.0)
	m.set_shader_parameter("wetness", 0.0)
	_env_mats.append(m)
	return _put(k, m) as ShaderMaterial


static func water_mat() -> ShaderMaterial:
	var k := "m_water"
	if _cache.has(k):
		return _cache[k]
	var m := ShaderMaterial.new()
	m.shader = load("res://src/shaders/water.gdshader")
	m.set_shader_parameter("noise_tex", noise())
	m.set_shader_parameter("night", 0.0)
	m.set_shader_parameter("wetness", 0.0)
	m.set_shader_parameter("rain", 0.0)
	_env_mats.append(m)
	return _put(k, m) as ShaderMaterial


static func road_mat(lanes: int, two_way: bool, width: float) -> ShaderMaterial:
	var k := "m_road_%d_%d" % [lanes, 1 if two_way else 0]
	if _road_mats.has(k):
		return _road_mats[k]
	var m := ShaderMaterial.new()
	m.shader = load("res://src/shaders/road.gdshader")
	m.set_shader_parameter("noise_tex", noise_fine())
	m.set_shader_parameter("lanes", float(maxi(lanes, 1)))
	m.set_shader_parameter("two_way", 1.0 if two_way else 0.0)
	m.set_shader_parameter("road_width", maxf(width, 1.0))
	m.set_shader_parameter("dash_len", 9.0 if lanes <= 4 else 12.0)
	m.set_shader_parameter("night", 0.0)
	m.set_shader_parameter("wetness", 0.0)
	_road_mats[k] = m
	_env_mats.append(m)
	return m


## Painted / metal / glass surfaces for landmarks and street furniture.
static func std(col: Color, rough: float = 0.7, metal: float = 0.0,
		emis: Color = Color(0, 0, 0, 0), emis_energy: float = 0.0) -> StandardMaterial3D:
	var key := "std_%s_%d_%d_%s_%d" % [col.to_html(true), int(rough * 100), int(metal * 100),
		emis.to_html(true), int(emis_energy * 10)]
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	if emis.a > 0.01:
		m.emission_enabled = true
		m.emission = emis
		m.emission_energy_multiplier = emis_energy
	if metal > 0.5:
		m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	return _put(key, m) as StandardMaterial3D


static func glow(col: Color, energy: float) -> StandardMaterial3D:
	return std(Color(0.02, 0.02, 0.02), 0.4, 0.0, col, energy)


## Night-reactive variant for signage and street lighting.
static func lamp_mat() -> StandardMaterial3D:
	var k := "m_lamp"
	if _cache.has(k):
		return _cache[k]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.05, 0.05, 0.06)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.82, 0.55)
	m.emission_energy_multiplier = 0.0
	m.roughness = 0.5
	return _put(k, m) as StandardMaterial3D


## Vertex-coloured clutter (poles, trees, walls, roof plant) shares one material so all
## merged props in a chunk are a single draw call.
static func props_mat() -> StandardMaterial3D:
	var k := "m_props"
	if _cache.has(k):
		return _cache[k]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.78
	m.metallic = 0.05
	return _put(k, m) as StandardMaterial3D


## Self-lit surfaces: signage, street lamps, aviation warning lights.
static func emissive_mat() -> StandardMaterial3D:
	var k := "m_emissive"
	if _cache.has(k):
		return _cache[k]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.emission_enabled = true
	m.emission = Color(1, 1, 1)
	m.emission_energy_multiplier = 1.0
	m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	m.albedo_color = Color(1, 1, 1, 1)
	m.roughness = 1.0
	_env_mats.append(m)
	return _put(k, m) as StandardMaterial3D


static func set_emissive_energy(e: float) -> void:
	var m: StandardMaterial3D = _cache.get("m_emissive")
	if m != null:
		m.emission_energy_multiplier = e


static func set_env(night: float, wetness: float, rain: float) -> void:
	for m in _env_mats:
		if m is ShaderMaterial:
			m.set_shader_parameter("night", night)
			m.set_shader_parameter("wetness", wetness)
		if m is ShaderMaterial and m.get_shader_parameter("rain") != null:
			m.set_shader_parameter("rain", rain)
	var lm: StandardMaterial3D = _cache.get("m_lamp")
	if lm != null:
		lm.emission_energy_multiplier = lerpf(0.05, 5.5, night)


# --- Primitive mesh cache ---------------------------------------------------
static func box(size: Vector3) -> BoxMesh:
	var k := "p_box_%s" % size
	if _cache.has(k):
		return _cache[k]
	var b := BoxMesh.new()
	b.size = size
	return _put(k, b) as BoxMesh


static func cyl(r: float, h: float, seg: int = 16, top_r: float = -1.0) -> CylinderMesh:
	var k := "p_cyl_%f_%f_%d_%f" % [r, h, seg, top_r]
	if _cache.has(k):
		return _cache[k]
	var c := CylinderMesh.new()
	c.top_radius = r if top_r < 0.0 else top_r
	c.bottom_radius = r
	c.height = maxf(h, 0.01)
	c.radial_segments = seg
	c.rings = 1
	return _put(k, c) as CylinderMesh


static func sphere(r: float, res: int = 12) -> SphereMesh:
	var k := "p_sph_%f_%d" % [r, res]
	if _cache.has(k):
		return _cache[k]
	var s := SphereMesh.new()
	s.radius = maxf(r, 0.01)
	s.height = maxf(r, 0.01) * 2.0
	s.radial_segments = res
	s.rings = maxi(res / 2, 3)
	return _put(k, s) as SphereMesh


static func plane(size: Vector2) -> PlaneMesh:
	var k := "p_pln_%s" % size
	if _cache.has(k):
		return _cache[k]
	var p := PlaneMesh.new()
	p.size = size
	return _put(k, p) as PlaneMesh


# --- Palette ----------------------------------------------------------------
## Concrete / granite / brick / curtain-wall tones pulled from Shanghai's actual
## colour temperature: warm grey stone in Puxi, cool glass in Pudong.
static func tint_for(style: String, r: float) -> Color:
	var c: Color
	match style:
		"cbd_tower":
			c = [Color(0.52, 0.58, 0.64), Color(0.40, 0.46, 0.53), Color(0.62, 0.64, 0.66),
				Color(0.33, 0.38, 0.44), Color(0.70, 0.66, 0.58)][int(r * 5) % 5]
		"historic_mix":
			c = [Color(0.62, 0.55, 0.47), Color(0.54, 0.44, 0.38), Color(0.68, 0.64, 0.58),
				Color(0.46, 0.37, 0.33), Color(0.72, 0.70, 0.64)][int(r * 5) % 5]
		"modern_mix":
			c = [Color(0.66, 0.65, 0.63), Color(0.50, 0.53, 0.57), Color(0.74, 0.72, 0.69),
				Color(0.43, 0.47, 0.51), Color(0.61, 0.58, 0.55)][int(r * 5) % 5]
		"old_industrial", "port_industry":
			c = [Color(0.48, 0.45, 0.42), Color(0.56, 0.40, 0.34), Color(0.40, 0.42, 0.44),
				Color(0.62, 0.58, 0.50)][int(r * 4) % 4]
		"campus_industrial":
			c = [Color(0.70, 0.67, 0.61), Color(0.55, 0.57, 0.60), Color(0.63, 0.52, 0.44),
				Color(0.76, 0.74, 0.70)][int(r * 4) % 4]
		"diplomatic":
			c = [Color(0.72, 0.66, 0.56), Color(0.58, 0.50, 0.44), Color(0.66, 0.62, 0.55),
				Color(0.50, 0.46, 0.42)][int(r * 4) % 4]
		"sprawl_tower":
			c = [Color(0.74, 0.70, 0.63), Color(0.60, 0.62, 0.64), Color(0.80, 0.77, 0.71),
				Color(0.52, 0.55, 0.58)][int(r * 4) % 4]
		"suburb", "rural":
			c = [Color(0.78, 0.75, 0.68), Color(0.62, 0.58, 0.53), Color(0.70, 0.66, 0.58)][int(r * 3) % 3]
		_:
			c = Color(0.62, 0.62, 0.62)
	c = c.lightened(0.06 * (r - 0.5))
	c.a = 0.0
	if style == "cbd_tower" and r > 0.80:
		c.a = 1.0		# flags the LED media-facade band in facade.gdshader
	return c
