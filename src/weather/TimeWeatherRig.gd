class_name TimeWeatherRig
extends Node3D
## Owns the sky, the sun, and the single direction that every time/weather value flows
## through: GameGlobals -> environment + shader uniforms. Subsystems never talk to each
## other, they only read GameGlobals, which is what makes them replaceable later.

const SUN_RANGES := {
	"dawn": 5.2, "sunrise": 6.4, "noon": 12.4, "sunset": 18.1, "dusk": 19.3,
}

var sun: DirectionalLight3D
var world_env: WorldEnvironment
var env: Environment
var sky: Sky
var sky_mat: ProceduralSkyMaterial
var glow_light: OmniLight3D

var _last_sky_hour := -99.0
var _night := 0.0
var _wet := 0.0


func _ready() -> void:
	add_to_group("world_environment")
	_build()
	GameGlobals.time_of_day_changed.connect(func(_h): _last_sky_hour = -99.0)
	GameGlobals.weather_changed.connect(func(_k, _i): _last_sky_hour = -99.0)


func _build() -> void:
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.16, 0.34, 0.68)
	sky_mat.sky_horizon_color = Color(0.62, 0.68, 0.76)
	sky_mat.ground_bottom_color = Color(0.10, 0.10, 0.11)
	sky_mat.ground_horizon_color = Color(0.42, 0.44, 0.48)
	sky_mat.sun_angle_max = 12.0
	sky_mat.sun_curve = 0.32
	sky = Sky.new()
	sky.sky_material = sky_mat

	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 12.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.08
	env.glow_enabled = true
	env.glow_intensity = 0.42
	env.glow_bloom = 0.04
	env.glow_normalized = true
	env.glow_hdr_threshold = 1.9
	env.fog_enabled = true
	env.fog_light_energy = 0.55
	env.fog_density = 0.000035
	env.fog_height = 420.0
	env.fog_aerial_perspective = 0.42
	env.volumetric_fog_enabled = false
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color(0.72, 0.78, 0.86)
	env.volumetric_fog_emission_energy = 0.0
	env.ssr_enabled = true

	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.rotation_order = 2
	sun.light_indirect_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 420.0
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.72
	add_child(sun)

	# A mobile probe keeps the river and wet asphalt reflecting the near skyline.
	glow_light = OmniLight3D.new()
	glow_light.light_energy = 0.0
	glow_light.omni_range = 90.0
	add_child(glow_light)


func apply_quality(c: Dictionary) -> void:
	if env == null:
		return
	env.ssr_enabled = bool(c["ssr"])
	env.volumetric_fog_enabled = bool(c["volumetric_fog"])


func _process(delta: float) -> void:
	# The clock runs only while the world is live; the editor freezes it so a placed building
	# is lit the same way from one edit to the next.
	if GameGlobals.is_playing():
		if GameGlobals.time_scale > 0.0:
			GameGlobals.advance_time(delta / GameGlobals.DAY_LENGTH_SEC * 24.0 * GameGlobals.time_scale)
	_update()


func _update() -> void:
	if sun == null or env == null:
		return
	var hour: float = GameGlobals.time_of_day
	var weather: int = GameGlobals.weather_kind
	var wint: float = GameGlobals.weather_intensity

	# --- sun geometry --------------------------------------------------------
	var dayt := (hour - SUN_RANGES["sunrise"]) / (SUN_RANGES["sunset"] - SUN_RANGES["sunrise"])
	var elev: float = sin(clampf(dayt, -0.35, 1.35) * PI) * 62.0
	var azim: float = lerpf(94.0, -94.0, clampf(dayt, 0.0, 1.0))
	var day_f := clampf((elev + 2.5) / 12.0, 0.0, 1.0)
	_night = 1.0 - day_f

	var overcast := 0.0
	match weather:
		GameGlobals.Weather.CLOUDY:
			overcast = 0.30 * wint
		GameGlobals.Weather.OVERCAST:
			overcast = 0.62 * wint
		GameGlobals.Weather.RAIN:
			overcast = 0.74 * wint
		GameGlobals.Weather.STORM, GameGlobals.Weather.TYPHOON:
			overcast = 0.90 * wint
		GameGlobals.Weather.FOG:
			overcast = 0.55 * wint
	var rain_f := 0.0
	if weather in [GameGlobals.Weather.RAIN, GameGlobals.Weather.STORM, GameGlobals.Weather.TYPHOON]:
		rain_f = wint
	_wet = clampf(_wet + (rain_f * 0.9 - _wet) * 0.02, 0.0, 1.0)

	if day_f > 0.02:
		sun.rotation_degrees = Vector3(-(90.0 - elev), azim, 0.0)
	else:
		sun.rotation_degrees = Vector3(-(90.0 - 24.0), 176.0, 0.0)
	sun.light_energy = lerpf(0.06, 1.35, day_f) * (1.0 - overcast * 0.72)
	sun.light_color = Color(0.42, 0.52, 0.78).lerp(Color(1.0, 0.80, 0.58),
		clampf(1.0 - absf(elev) / 22.0, 0.0, 1.0)) if day_f > 0.02 else Color(0.55, 0.64, 0.88)
	sun.light_color = sun.light_color.lerp(Color(0.78, 0.82, 0.90), overcast * 0.7)
	sun.shadow_opacity = lerpf(0.86, 0.24, overcast)

	# --- sky -----------------------------------------------------------------
	# Radiance for a parametric sky is a real texture regeneration, so it is throttled to
	# roughly a ten-minute in-game step rather than run every frame.
	if absf(hour - _last_sky_hour) > 0.04:
		_last_sky_hour = hour
		_paint_sky(day_f, overcast, rain_f, weather)

	# --- fog / aerial --------------------------------------------------------
	var base_fog := 0.000030
	match weather:
		GameGlobals.Weather.FOG:
			base_fog = 0.00042 * (0.4 + wint)
		GameGlobals.Weather.STORM:
			base_fog = 0.00016
		GameGlobals.Weather.TYPHOON:
			base_fog = 0.00028
		_:
			base_fog = 0.000030 + 0.000022 * rain_f
	env.fog_density = base_fog
	env.fog_light_energy = lerpf(0.55, 0.16, _night) * (1.0 - overcast * 0.3)
	env.fog_aerial_perspective = lerpf(0.55, 0.16, overcast)
	env.volumetric_fog_density = 0.0
	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = lerpf(0.0035, 0.026, clampf(maxf(rain_f, overcast * 0.6), 0.0, 1.0))
		env.volumetric_fog_emission_energy = lerpf(0.0, 0.06, _night)

	env.ambient_light_energy = lerpf(0.44, 0.95, day_f) * (1.0 + overcast * 0.30)
	env.glow_intensity = lerpf(0.30, 0.88, _night)
	env.glow_bloom = lerpf(0.02, 0.10, _night)
	env.glow_hdr_threshold = lerpf(2.6, 0.85, _night)
	env.background_energy_multiplier = lerpf(1.0, 1.22, overcast * 0.4)

	# Street-level pool of light that lifts the player's immediate surroundings at night.
	# Real lamps are emissive-only geometry, so this stands in for their bounce without
	# the cost of a dynamic light per pole.
	glow_light.light_energy = lerpf(0.0, 2.6, _night)
	glow_light.light_color = Color(1.0, 0.72, 0.42)
	var pv := get_tree().get_first_node_in_group("player")
	if pv is Node3D:
		glow_light.global_position = (pv as Node3D).global_position + Vector3(0.0, 5.5, 0.0)

	Assets.set_env(_night, _wet, rain_f)
	Assets.set_emissive_energy(lerpf(0.10, 7.5, _night))


func _paint_sky(day_f: float, overcast: float, rain_f: float, weather: int) -> void:
	var is_night := day_f < 0.06
	var dusk := clampf(1.0 - absf(day_f - 0.30) / 0.34, 0.0, 1.0)
	var top := Color(0.010, 0.015, 0.034)
	var hor := Color(0.055, 0.062, 0.090)
	if is_night:
		# A megacity never goes truly black at the horizon — sodium light pollution.
		hor = Color(0.14, 0.095, 0.062)
		top = Color(0.009, 0.014, 0.030)
	else:
		top = Color(0.085, 0.17, 0.42).lerp(Color(0.16, 0.36, 0.72), clampf(day_f, 0.0, 1.0))
		hor = Color(0.72, 0.60, 0.46).lerp(Color(0.68, 0.76, 0.86), clampf(day_f * 1.5, 0.0, 1.0))
		hor = hor.lerp(Color(0.94, 0.42, 0.20), dusk * 0.72)
		top = top.lerp(Color(0.34, 0.22, 0.20), dusk * 0.42)
	if weather == GameGlobals.Weather.STORM or weather == GameGlobals.Weather.TYPHOON:
		top = top.lerp(Color(0.055, 0.062, 0.075), 0.85)
		hor = hor.lerp(Color(0.11, 0.12, 0.135), 0.85)
	else:
		top = top.lerp(Color(0.44, 0.46, 0.49), overcast * 0.82)
		hor = hor.lerp(Color(0.56, 0.575, 0.59), overcast * 0.82)
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = hor
	sky_mat.ground_horizon_color = hor.darkened(0.32).lerp(Color(0.42, 0.42, 0.44), overcast)
	sky_mat.ground_bottom_color = Color(0.055, 0.055, 0.060).lerp(Color(0.16, 0.16, 0.17), overcast)
	env.fog_light_color = hor.lightened(0.08) if not is_night else Color(0.06, 0.07, 0.10)


func night_factor() -> float:
	return _night


func wet_factor() -> float:
	return _wet
