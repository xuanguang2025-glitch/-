shader_type spatial;

// Street furniture, barriers, viaduct skirts, walls and roof plant all share one merged mesh
// and one material per chunk, so every detail here has to come from world position and the
// vertex colour — a second material would double the draw calls the streaming budget assumes.
//
// `anchored` exists because these surfaces are used by both static geometry and moving things:
// world-space mottling on a pedestrian or a sedan slides across the surface as it moves, which
// reads as shimmering. Moving instances ask for anchored = 0 and get the plain flat look back.

uniform float anchored : hint_range(0.0, 1.0) = 1.0;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D noise_tex : filter_linear_mipmap;

varying vec3 v_world;
varying vec3 v_nrm;
varying vec4 v_col;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_col = COLOR;
}

void fragment() {
	vec3 alb = v_col.rgb;
	float up = 1.0 - abs(v_nrm.y);
	float rough = 0.78;

	if (anchored > 0.5) {
		// Cast panels and precast units never match their neighbour batch for colour, and a
		// large flat face with one grey is the single biggest "white plastic" tell on the
		// viaducts.
		float m = texture(noise_tex, v_world.xz * 0.25 + v_world.yy * 0.1).r;
		alb *= 0.90 + 0.20 * m;
		rough -= 0.14 * m;
		// Rain streaks run down vertical faces. They stop being relevant on soffits.
		float streak = texture(noise_tex,
			vec2(v_world.x * 0.6 + v_world.z * 0.6, v_world.y * 0.05)).r;
		alb *= mix(vec3(1.0), vec3(0.86, 0.855, 0.845), up * smoothstep(0.35, 0.85, streak));
		// Everything is dirtier within arm's reach of the ground.
		alb *= 1.0 - 0.20 * clamp(1.0 - v_world.y / 1.1, 0.0, 1.0) * up;
	}

	// Wet concrete darkens and picks up specular; paint and metal less so, but this is one
	// material and cannot tell them apart, so the effect is deliberately mild.
	alb *= 1.0 - wetness * 0.18;
	rough *= 1.0 - wetness * 0.5;

	ALBEDO = alb;
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	METALLIC = 0.05;
	SPECULAR = 0.4;
	ALPHA = 1.0;
}
