shader_type spatial;
// The river ribbon is generated from a centreline whose winding is not guaranteed
// per-segment, so culling the back face leaves the water invisible from the bank.
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

// Huangpu / Suzhou Creek. Silty tidal water with a distorted screen-space mirror of
// the skyline — that mirror is what makes the Bund at night read as Shanghai.

uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float rain : hint_range(0.0, 1.0) = 0.0;
uniform float time_scale = 1.0;
uniform float ripple = 1.0;
uniform vec3 shallow_col = vec3(0.10, 0.13, 0.115);
uniform vec3 deep_col = vec3(0.028, 0.048, 0.050);
uniform float reflect_strength = 0.85;

uniform sampler2D noise_tex : filter_linear_mipmap;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

varying vec3 v_world;
varying vec3 v_nrm;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float d = distance(v_world.xyz, CAMERA_POSITION_WORLD.xyz);
	float amp = clamp(1.0 - d / 900.0, 0.0, 1.0) * ripple;
	VERTEX.y += sin(v_world.x * 0.055 + TIME * 0.75 * time_scale) * 0.22 * amp;
	VERTEX.y += sin(v_world.z * 0.041 - TIME * 0.53 * time_scale) * 0.18 * amp;
}

float wave_n(vec2 p, float t) {
	float a = sin(p.x * 0.13 + t * 1.1) * 0.5
		+ sin(p.y * 0.17 - t * 0.9) * 0.5
		+ sin((p.x + p.y) * 0.07 + t * 0.4) * 0.4;
	return a;
}

void fragment() {
	vec2 wp = vec2(v_world.x, v_world.z);
	float t = TIME * time_scale;

	// Layered detail normal: long tidal swell + wind chop + rain pitter-pat.
	vec2 q1 = wp * 0.021 + vec2(t * 0.030, t * 0.017);
	vec2 q2 = wp * 0.085 - vec2(t * 0.075, t * 0.052);
	vec2 q3 = wp * 0.42 + vec2(t * 0.20, -t * 0.24);

	vec3 n;
	n.x = wave_n(q1, t) * 0.30 + wave_n(q2, t * 1.7) * 0.14 + wave_n(q3, t * 2.9) * 0.035 * rain;
	n.z = wave_n(q1.yx + 3.1, t * 1.05) * 0.30 + wave_n(q2.yx + 7.7, t * 1.6) * 0.14
		+ wave_n(q3.yx, t * 3.1) * 0.035 * rain;
	n.y = 1.0;
	n = normalize(n);

	float foam_edge = clamp(texture(noise_tex, wp * 0.006 + vec2(t * 0.004, 0.0)).r, 0.0, 1.0);
	// Rain hammers the whole surface into micro-roughness.
	float chop = mix(1.0, 1.9, rain);

	vec3 vd = normalize(v_world - CAMERA_POSITION_WORLD);
	vec3 refl = reflect(vd, n);
	float fres = pow(clamp(1.0 - dot(refl, -vd), 0.0, 1.0), 4.0);
	fres = mix(0.035, 1.0, fres);

	// Screen-space mirror of the opposite bank, wobbled by the normal.
	vec2 suv = SCREEN_UV + refl.xz * 0.055 * clamp(1.0 - fres, 0.0, 1.0);
	suv = clamp(suv, vec2(0.001), vec2(0.999));
	vec3 mirror = texture(screen_texture, suv).rgb;
	// Blur by sampling a few taps so reflections don't look like a cut-out.
	mirror += texture(screen_texture, suv + vec2(0.0018, 0.0011) * chop).rgb;
	mirror += texture(screen_texture, suv - vec2(0.0015, 0.0019) * chop).rgb;
	mirror += texture(screen_texture, suv + vec2(0.0022, -0.0014) * chop).rgb;
	mirror *= 0.25;
	// At night the mirror is mostly neon: saturate and boost it.
	mirror = mix(mirror, mirror * vec3(1.15, 0.95, 1.35) * 1.5, night);

	vec3 body = mix(shallow_col, deep_col, 0.65);
	vec3 water = mix(body, mirror, clamp(fres * reflect_strength, 0.0, 0.94));

	// Sky sheen along grazing angles keeps the far bank from going black.
	float graze = pow(clamp(1.0 - abs(dot(-vd, vec3(0.0, 1.0, 0.0))), 0.0, 1.0), 3.0);
	water += vec3(0.10, 0.13, 0.18) * graze * (0.25 + night * 0.35);

	vec3 whitecaps = vec3(0.86, 0.90, 0.92) * smoothstep(0.62, 0.94, foam_edge) * (0.10 + rain * 0.55);

	ALBEDO = water + whitecaps;
	ROUGHNESS = mix(0.06, 0.26, rain * 0.6) * (1.0 - wetness * 0.2);
	METALLIC = 0.0;
	SPECULAR = 0.35;
	EMISSION = whitecaps * 0.15;
	NORMAL = n;
}
