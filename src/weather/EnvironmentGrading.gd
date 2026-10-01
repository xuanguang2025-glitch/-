class_name EnvironmentGrading
extends RefCounted
## Owns how light is *graded* on the way to the camera: tonemapper, exposure, ambient and global
## illumination sourcing, screen-space contact shadows, bloom and haze. `TimeWeatherRig` keeps
## owning the sun and the sky; this file owns what the sensor does with them.
##
## Why this exists as its own file: the quality tiers have declared `"sdfgi": true` on 高/极致
## since they were written, and nothing in the codebase ever read that key. The advertised global
## illumination was a label, which is the specific kind of fake the spec forbids — so the wiring
## lives here where it can be pointed at, measured and screenshotted.
##
## The realism budget, in the order it actually shows up on screen:
##   1. exposure — a midday frame that reads as dusk is not a texture problem
##   2. indirect light — flat black facades and floating objects are missing bounce and contact
##   3. the tonemapper's highlight behaviour — emissive windows clipping to neon is a sensor artefact
##   4. surface micro-detail — grime, aggregate, wear

## Sun angular diameter in degrees. The real value is ~0.53, and it is what gives a shadow edge
## its penumbra: at 0 the sun is a point light and every shadow is a hard cut-out.
const SUN_ANGULAR_DEG := 0.53

## Colour temperature along the day curve. Noon is close to D65, sunrise/sunset is the warm low
## angle, and "night" is moonlight, which is cool and very dim rather than black.
const K_NOON := 6400.0
const K_HORIZON := 3300.0
const K_NIGHT := 11500.0


# Base configuration, applied once when the environment is built.
static func configure(env: Environment, sky: Sky) -> void:
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# AgX over Filmic/ACES: it rolls highlights off the way film does and desaturates them, which
	# is what stops a wall of lit windows from turning into flat neon dots.
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.0
	# AgX already keeps highlights from clipping; saturation above 1.0 is what made the city read
	# as a toy. Grading pulls it back, the surfaces themselves stay at real-world reflectance.
	env.adjustment_saturation = 0.86

	env.glow_enabled = true
	env.glow_normalized = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_bloom = 0.02
	env.glow_mix = 0.95
	env.glow_hdr_luminance_cap = 24.0

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	# Forward scattering: the sun through haze is a shaft, not a uniform wash.
	env.fog_sun_scatter = 0.22
	env.volumetric_fog_anisotropy = 0.58
	env.volumetric_fog_sky_affect = 0.65
	env.volumetric_fog_gi_inject = 0.6

	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.1
	env.ssr_fade_out = 0.3
	env.ssr_depth_tolerance = 0.15

	# Contact darkening where surfaces meet. Radius is in metres and city geometry is metres, so
	# the engine default (2.0) is right for a room and slightly loose for a street; kept near it.
	env.ssao_enabled = true
	env.ssao_radius = 1.8
	env.ssao_intensity = 1.15
	env.ssao_power = 1.0
	env.ssao_detail = 0.35
	env.ssao_horizon = 0.0
	env.ssao_sharpness = 0.0
	env.ssao_light_affect = 0.45
	env.ssao_ao_channel_affect = 0.0

	# SDFGI tuned for city scale: cascades have to reach past a 100 m block, and vertical
	# resolution matters more than horizontal because towers are the dominant form.
	env.sdfgi_enabled = true
	env.sdfgi_read_sky_light = true
	env.sdfgi_use_occlusion = true
	env.sdfgi_bounce_feedback = 0.75
	env.sdfgi_cascades = 4
	env.sdfgi_cascade0_distance = 40.0
	env.sdfgi_max_distance = 400.0
	env.sdfgi_min_cell_size = 0.35
	env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_75_PERCENT
	env.sdfgi_energy = 1.15
	env.sdfgi_normal_bias = 1.1
	env.sdfgi_probe_bias = 1.1


# Tier wiring. This is the only place that decides whether bounce light and contact shadows
# exist, so `QualityPresets`' `sdfgi` / `ssao` keys stop being documentation.
static func apply_tier(env: Environment, c: Dictionary) -> void:
	if env == null:
		return
	env.ssr_enabled = bool(c["ssr"])
	env.volumetric_fog_enabled = bool(c["volumetric_fog"])
	env.sdfgi_enabled = bool(c["sdfgi"])
	env.ssao_enabled = bool(c.get("ssao", true))
	if env.sdfgi_enabled:
		var ultra: bool = int(c.get("sdfgi_cascades", 4)) > 4
		env.sdfgi_cascades = mini(int(c.get("sdfgi_cascades", 4)), 8)
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_100_PERCENT if ultra \
			else Environment.SDFGI_Y_SCALE_75_PERCENT
		env.sdfgi_max_distance = float(c.get("sdfgi_max_distance", 400.0))
	# A city with no bounce light and no contact shadows is the cartoon look, so the low tier
	# keeps AO and pays for it by dropping reflections and volumetrics instead.
	if int(c.get("ssao_quality", 1)) == 0:
		env.ssao_intensity = 0.9


# Per-frame grading. Mutates only sensor-side values; sun geometry and sky paint stay in
# `TimeWeatherRig` because those are world-side facts.
static func grade(env: Environment, day_f: float, night: float, overcast: float, wet: float) -> void:
	if env == null:
		return
	# Exposure, not sun energy, carries the day/night range: a sensor that opens at night keeps
	# the highlights behaving like daylight does, which is why shopfronts bloom instead of the
	# whole street lifting.
	env.tonemap_exposure = lerpf(1.75, 0.92, day_f)
	env.ambient_light_energy = lerpf(0.16, 0.55, day_f) * (1.0 + overcast * 0.35)
	env.background_energy_multiplier = lerpf(0.85, 1.0, day_f)

	env.fog_light_energy = lerpf(0.06, 0.42, day_f) * (1.0 - overcast * 0.25)
	env.fog_sky_affect = lerpf(0.45, 0.9, day_f)
	env.fog_aerial_perspective = lerpf(0.30, 0.62, day_f) * (1.0 - overcast * 0.5)

	env.glow_intensity = lerpf(0.55, 0.12, day_f)
	env.glow_hdr_threshold = lerpf(1.15, 4.2, day_f)
	env.glow_bloom = lerpf(0.035, 0.012, day_f)

	# Wet streets reflect the sky instead of absorbing it, so reflections have to be trusted
	# more and contact darkening less once the ground is a mirror.
	env.ssr_enabled = env.ssr_enabled or wet > 0.35
	env.ssao_intensity = lerpf(1.15, 0.8, wet)

	if env.sdfgi_enabled:
		# Bounce carries the night city: without it, facades away from the lamps go black, which
		# is the "boxes with dots" read. Overcast flattens it, clear nights lean on it.
		env.sdfgi_energy = lerpf(0.85, 1.25, day_f) * lerpf(1.15, 0.95, overcast)


# Approximate blackbody colour for a temperature in kelvin, normalised so 6400 K is white.
# Done here rather than with `Light3D.light_temperature` because that property only takes
# effect under the physical light units, and switching units would change every other light.
static func kelvin(k: float) -> Color:
	var c := _blackbody(k)
	if not _white_ready:
		# Cached: this divides every colour the sun takes, and computing it is the same work as
		# converting a temperature.
		_white_ref = _blackbody(6400.0)
		_white_ready = true
	return Color(c.r / maxf(_white_ref.r, 0.001), c.g / maxf(_white_ref.g, 0.001),
		c.b / maxf(_white_ref.b, 0.001))


static var _white_ref := Color()
static var _white_ready := false


## Tanner-Helland style blackbody fit, unnormalised — 6400 K comes out near (1, 1, 1) already.
static func _blackbody(k: float) -> Color:
	var t := k / 100.0
	var r: float
	var g: float
	var b: float
	if t <= 66.0:
		r = 255.0
		g = 99.4708025861 * log(t) - 161.1195681661
	else:
		r = 329.698727446 * pow(clampf(t - 60.0, 0.01, 1000.0), -0.1332047592)
		g = 288.1221695283 * pow(clampf(t - 60.0, 0.01, 1000.0), -0.0755148492)
	if t >= 66.0:
		b = 255.0
	elif t <= 19.0:
		b = 0.0
	else:
		b = 138.5177312231 * log(t - 10.0) - 305.0447927307
	return Color(clampf(r, 0.0, 255.0) / 255.0, clampf(g, 0.0, 255.0) / 255.0,
		clampf(b, 0.0, 255.0) / 255.0)
