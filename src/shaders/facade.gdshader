shader_type spatial;
render_mode depth_draw_always;

// Procedural building facade — the stand-in for Nanite + authored textures.
// One material covers every merged building in a chunk; window grids, mullions,
// floor bands, shopfronts and rooftop membrane are all derived from world
// position, so a 400-tower chunk is still a single draw call.

uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float win_w : hint_range(1.0, 8.0) = 3.10;
uniform float win_h : hint_range(1.0, 8.0) = 3.55;
uniform float occupancy : hint_range(0.0, 1.0) = 0.62;
uniform float glass_tint_shift = 0.0;
uniform sampler2D noise_tex : filter_linear_mipmap;

varying vec3 v_world;
varying vec3 v_nrm;
varying vec4 v_col;

float h12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_col = COLOR;
}

void fragment() {
	bool roof = v_nrm.y > 0.65;
	float floor_y = v_world.y;

	// ---- planar facade UV, chosen by face orientation so boxes tile cleanly ----
	vec2 uv;
	if (abs(v_nrm.x) > abs(v_nrm.z)) {
		uv = vec2(v_world.z, floor_y);
	} else {
		uv = vec2(v_world.x, floor_y);
	}

	float mull = 0.16;
	vec2 cell = floor(vec2(uv.x / win_w, uv.y / win_h));
	vec2 f = fract(vec2(uv.x / win_w, uv.y / win_h));

	// Floor slab bands every storey: real towers read as horizontal lines.
	float band = smoothstep(0.90, 0.965, f.y) + smoothstep(0.10, 0.035, f.y);
	band = clamp(band, 0.0, 1.0);

	float in_x = step(mull, f.x) * step(f.x, 1.0 - mull);
	float in_y = step(0.20, f.y) * step(f.y, 0.82);
	float pane = in_x * in_y;

	// Podium / shopfront: ground storey is taller glass with warm interior light.
	float podium = 1.0 - smoothstep(4.2, 7.4, floor_y);

	// ---- window state -------------------------------------------------------
	float r = h12(cell + floor_y * 0.001 + glass_tint_shift);
	float r2 = h12(cell * 1.7 + 11.3);
	float lit_now = step(1.0 - occupancy, r);
	// Some panes stay dark all day (offices), most light up at night.
	float lit = mix(step(0.985, r2), lit_now, night);

	vec3 conc = v_col.rgb * vec3(0.86, 0.84, 0.82);
	vec3 glass = mix(vec3(0.055, 0.075, 0.095), vec3(0.10, 0.13, 0.15), h12(cell * 0.31));
	// Spandrel / mullion metal
	vec3 metal = v_col.rgb * vec3(0.40, 0.40, 0.42);

	vec3 alb = conc;
	alb = mix(alb, glass, pane * (1.0 - band));
	alb = mix(alb, metal, clamp(band + (1.0 - in_x) * 0.30, 0.0, 1.0));

	// A shopfront is a lit room seen through glass: bright near its own floor, dark under the
	// ceiling band, different from its neighbour. A uniform glowing rectangle reads as a decal.
	float shop_depth = smoothstep(0.12, 0.88, 1.0 - f.y);
	float shop_room = 0.55 + 0.75 * h12(cell * 1.9 + 3.3);
	if (podium > 0.5 && !roof) {
		alb = mix(alb, vec3(0.030, 0.033, 0.040), pane);
	}

	if (roof) {
		float gravel = texture(noise_tex, uv * 0.35).r;
		alb = mix(vec3(0.10, 0.10, 0.11), vec3(0.19, 0.185, 0.175), gravel);
		pane = 0.0;
		lit = 0.0;
	}

	float rough = 0.82;
	rough = mix(rough, 0.14, pane * (1.0 - band));
	rough = mix(rough, 0.55, band);
	if (roof) { rough = 0.92; }
	rough *= 1.0 - wetness * 0.72;

	float ao = 1.0 - 0.30 * (1.0 - pane) * (roof ? 0.0 : 1.0);

	vec3 warm = vec3(1.0, 0.74, 0.42);
	vec3 cool = vec3(0.62, 0.80, 1.0);
	vec3 light_col = mix(warm, cool, step(0.62, r2));
	// Office floors glow as strips, not perfect rectangles — reads less CG.
	float glow_shape = pane * (0.55 + 0.45 * smoothstep(0.1, 0.42, f.y));
	// A lit window is a dim warm rectangle behind glass, not a bare lamp. Emitting near 1.5 made
	// the whole skyline clip to white once night bloom was on, which is exactly the cartoon read;
	// per-pane wattage keeps a tower from being a uniform grid of identical dots.
	float pane_watt = 0.55 + 0.75 * h12(cell * 3.77 + 5.1);
	vec3 emis = light_col * glow_shape * lit * (0.22 + 0.30 * night) * pane_watt;
	if (podium > 0.5 && !roof) {
		emis += vec3(1.0, 0.80, 0.52) * pane * (0.10 + night * 0.30) * shop_depth * shop_room;
	}
	if (roof) {
		emis = vec3(0.0);
	}

	// LED media facade bands on the tallest towers (v_col.a flags them at build time)
	if (v_col.a > 0.5 && !roof) {
		float stripe = step(0.5, fract(v_world.y * 0.32 + uv.x * 0.03));
		emis += vec3(0.10, 0.35, 0.85) * stripe * pane * (0.10 + night * 0.75);
	}

	ALBEDO = alb;
	ROUGHNESS = rough;
	METALLIC = mix(0.05, 0.55, pane * (1.0 - band));
	SPECULAR = mix(0.42, 0.65, pane);
	EMISSION = emis;
	AO = ao;
}
