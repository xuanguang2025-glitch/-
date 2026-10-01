shader_type spatial;

// Terrain and hardscape. Vertex colour carries both the tint (rgb) and the surface
// code (a): 0 earth, 1 grass, 2 pavement slab, 3 plaza stone, 4 concrete, 5 track,
// 6 sand/mud bank, 7 construction deck.

uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float grass_bias = 1.0;
uniform sampler2D noise_tex : filter_linear_mipmap;

varying vec3 v_world;
varying vec4 v_col;
varying vec3 v_nrm;

float h12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_col = COLOR;
	v_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 wp = v_world.xz;
	float code = floor(v_col.a * 7.5 + 0.25);
	float fine = texture(noise_tex, wp * 0.35).r;
	float broad = texture(noise_tex, wp * 0.021).r;

	vec3 alb = v_col.rgb;
	float rough = 0.95;
	float spec = 0.25;

	if (code < 0.5) {
		// Bare earth / construction plot
		alb *= 0.72 + 0.5 * fine;
		rough = 0.98;
	} else if (code < 1.5) {
		// Grass: clumped, yellower than a default lawn, the way urban turf actually looks
		vec3 g1 = vec3(0.075, 0.155, 0.062);
		vec3 g2 = vec3(0.165, 0.245, 0.090);
		vec3 g3 = vec3(0.290, 0.275, 0.115);
		float t = smoothstep(0.35, 0.75, broad);
		alb = mix(g1, g2, fine) * mix(vec3(1.0), g3 / max(g2, vec3(0.01)), (1.0 - grass_bias) * 0.5);
		alb = mix(alb, alb * vec3(1.25, 1.15, 0.72), 1.0 - t);
		rough = 0.94;
	} else if (code < 2.5) {
		// Pavement: 0.6 m slabs with joints
		vec2 gj = abs(fract(wp / 0.6) - 0.5);
		float joint = 1.0 - smoothstep(0.44, 0.49, max(gj.x, gj.y));
		alb *= (0.80 + 0.28 * fine) * mix(0.62, 1.0, joint);
		rough = mix(0.90, 0.70, joint);
	} else if (code < 3.5) {
		// Plaza stone: large boards laid in modules
		vec2 pj = abs(fract(wp / 2.4) - 0.5);
		float joint = 1.0 - smoothstep(0.465, 0.495, max(pj.x, pj.y));
		float checker = step(0.5, fract(wp.x / 4.8)) - step(0.5, fract(wp.y / 4.8));
		alb *= (0.86 + 0.22 * fine) * mix(0.55, 1.0, joint);
		alb = mix(alb, alb * 1.18, abs(checker) * 0.35);
		rough = 0.52;
		spec = 0.45;
	} else if (code < 4.5) {
		// Cast concrete in sawn panels. The joint grid is what makes a 60 m slab read as a built
		// surface instead of an infinite plane, and the dust in the joints is what makes it read
		// as maintained rather than new.
		vec2 jd = abs(fract(wp / 4.5 + 0.5) - 0.5);
		float joint = 1.0 - smoothstep(0.474, 0.492, max(jd.x, jd.y));
		float stain = texture(noise_tex, wp * 0.055).r;
		alb *= (0.80 + 0.26 * fine) * mix(1.0, 0.60, joint);
		alb *= mix(vec3(1.0), vec3(0.87, 0.85, 0.80), smoothstep(0.45, 0.95, stain) * 0.5);
		rough = mix(0.90, 0.70, joint);
	} else if (code < 5.5) {
		// Compacted track
		alb *= 0.66 + 0.42 * broad;
		rough = 0.99;
	} else if (code < 6.5) {
		// Mud / sand bank at the waterline
		alb *= 0.78 + 0.34 * fine;
		rough = 0.72;
	} else {
		// Site deck
		alb *= 0.70 + 0.20 * fine;
		rough = 0.80;
	}

	if (code > 1.5) {
		// Hardscape is laid panel by panel, no two batches of mix match, and none of it is as
		// bright as a default material — clean concrete sits near 0.45 albedo and weathered
		// stone below that. Without this the plaza reads as an unlit sheet of paper.
		float panel = h12(floor(wp / 4.5));
		alb *= mix(vec3(0.66, 0.665, 0.69), vec3(0.88, 0.875, 0.86), panel);
	}

	// Aggregate: hardscape is a million small facets, so roughness varies at centimetre scale.
	// Without it a sunlit plaza is one matte sheet, which is a large part of the toy look.
	rough = clamp(rough + (texture(noise_tex, wp * 1.7).r - 0.5) * 0.16, 0.04, 1.0);

	// Wet ground darkens hard and turns specular — the雨后 asphalt-and-stone look.
	alb *= 1.0 - wetness * 0.42;
	rough = mix(rough, rough * 0.18, wetness);
	spec = mix(spec, 0.65, wetness);

	// Gentle slope darkens a touch (contact shading where ground meets structure)
	float slope = 1.0 - clamp(v_nrm.y, 0.0, 1.0);

	ALBEDO = alb * (1.0 - slope * 0.18);
	ROUGHNESS = clamp(rough, 0.04, 1.0);
	METALLIC = 0.0;
	SPECULAR = spec;
	EMISSION = vec3(0.02, 0.017, 0.012) * night * step(2.5, code) * step(code, 3.5) * 0.6;
}
