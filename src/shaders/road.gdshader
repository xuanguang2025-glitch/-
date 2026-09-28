shader_type spatial;

// Asphalt with road paint. UV is metric: uv.x = distance along the carriageway in
// metres, uv.y = 0 at one kerb to 1 at the other.

uniform float lanes = 4.0;
uniform float road_width = 20.0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float two_way : hint_range(0.0, 1.0) = 1.0;
uniform float dash_len = 9.0;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float tyre_wear = 1.0;
uniform sampler2D noise_tex : filter_linear_mipmap;

varying vec2 v_uv;
varying vec3 v_world;

void vertex() {
	v_uv = UV;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float across = clamp(v_uv.y, 0.0, 1.0);
	float along = v_uv.x;

	float grain = texture(noise_tex, vec2(along * 0.07, across * 3.0)).r;
	float patch = texture(noise_tex, vec2(along * 0.012, across * 0.6)).r;

	vec3 asphalt = mix(vec3(0.050, 0.050, 0.056), vec3(0.118, 0.116, 0.115), grain);
	// Wheel paths get polished and lighter; the middle and the gutter stay rough.
	float lane_pos = fract(across * max(lanes, 1.0));
	float wheel = smoothstep(0.12, 0.30, lane_pos) * smoothstep(0.88, 0.70, lane_pos);
	asphalt *= mix(1.06, 0.86, wheel * tyre_wear);
	asphalt *= 0.88 + 0.12 * smoothstep(0.0, 0.05, across) * smoothstep(1.0, 0.95, across);
	asphalt = mix(asphalt, asphalt * 0.66, step(0.83, patch));

	// ---- paint --------------------------------------------------------------
	float lane_unit = 1.0 / max(lanes, 1.0);
	float lw = 0.17 / max(road_width, 1.0);
	float d_line = abs(fract(across / lane_unit + 0.5) - 0.5) * lane_unit;
	float on_line = 1.0 - step(lw, d_line);

	float d_center = abs(across - 0.5);
	float dyc = abs(d_center - lw * 1.7);
	float on_center = (1.0 - step(lw * 0.9, dyc)) * two_way;

	float k = floor(across / lane_unit + 0.5);
	float is_edge = step(k, 0.5) + step(lanes - 0.5, k);
	is_edge = clamp(is_edge, 0.0, 1.0);

	float dash = step(0.42, fract(along / dash_len));
	float solid = clamp(is_edge + on_center, 0.0, 1.0);
	float white = on_line * (1.0 - on_center) * mix(dash, 1.0, solid);
	float yellow = on_center;

	float paint = clamp(white + yellow, 0.0, 1.0);
	vec3 paint_col = mix(vec3(0.80, 0.79, 0.74), vec3(0.86, 0.63, 0.06), yellow);

	vec3 alb = mix(asphalt, paint_col, paint);

	float rough = 0.90;
	rough = mix(rough, 0.30, paint);
	rough = mix(rough, rough * 0.80, wheel * tyre_wear);
	rough *= 1.0 - wetness * 0.78;
	// Paint stays grippy-ish even when wet, unlike the slick tarmac around it.
	rough = mix(rough, 0.45, paint * wetness);

	ALBEDO = alb;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = mix(0.30, 0.68, wetness);
	// Road markings bounce headlight back at the driver.
	EMISSION = paint_col * paint * (0.015 + wetness * 0.05) * night;
}
