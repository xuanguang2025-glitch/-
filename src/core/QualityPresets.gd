extends Node
## Quality tiers. Mirrors what a UE5 scalable-quality graph would do, and is the single
## place that decides shadow resolution, stream radius, and agent budgets.

enum Tier { LOW, MEDIUM, HIGH, ULTRA }

signal tier_changed(tier: int)

var tier: int = Tier.MEDIUM

const PRESETS := {
	Tier.LOW: {
		"label": "低",
		"camera_far": 1400.0,
		"shadow_size": 2048,
		"shadow_splits": 1,
		"stream_radius": 4,
		"sim_radius": 2,
		"ssr": false,
		"sdfgi": false,
		"volumetric_fog": false,
		"msaa": 0,
		"scale": 0.85,
		"npc_budget": 90,
		"vehicle_budget": 26,
		"particle_scale": 0.35,
		"lod_bias": 0.7,
	},
	Tier.MEDIUM: {
		"label": "中",
		"camera_far": 3600.0,
		"shadow_size": 4096,
		"shadow_splits": 2,
		"stream_radius": 6,
		"sim_radius": 3,
		"ssr": true,
		"sdfgi": false,
		"volumetric_fog": false,
		"msaa": 2,
		"scale": 1.0,
		"npc_budget": 260,
		"vehicle_budget": 60,
		"particle_scale": 0.7,
		"lod_bias": 1.0,
	},
	Tier.HIGH: {
		"label": "高",
		"camera_far": 7000.0,
		"shadow_size": 8192,
		"shadow_splits": 4,
		"stream_radius": 8,
		"sim_radius": 4,
		"ssr": true,
		"sdfgi": true,
		"volumetric_fog": true,
		"msaa": 4,
		"scale": 1.0,
		"npc_budget": 520,
		"vehicle_budget": 110,
		"particle_scale": 1.0,
		"lod_bias": 1.35,
	},
	Tier.ULTRA: {
		"label": "极致",
		"camera_far": 12000.0,
		"shadow_size": 16384,
		"shadow_splits": 4,
		"stream_radius": 10,
		"sim_radius": 5,
		"ssr": true,
		"sdfgi": true,
		"volumetric_fog": true,
		"msaa": 8,
		"scale": 1.0,
		"npc_budget": 900,
		"vehicle_budget": 170,
		"particle_scale": 1.0,
		"lod_bias": 1.8,
	},
}


func _ready() -> void:
	set_tier(tier)


func cfg() -> Dictionary:
	return PRESETS[tier]


func tier_name(t: int) -> String:
	return String(PRESETS[t]["label"])


func tier_count() -> int:
	return PRESETS.size()


func set_tier(next: int) -> void:
	tier = clampi(next, 0, PRESETS.size() - 1)
	var c: Dictionary = PRESETS[tier]
	RenderingServer.directional_shadow_atlas_set_size(c["shadow_size"], true)
	for group in ["world_environment", "camera", "streamer", "crowd", "traffic", "weather"]:
		get_tree().call_group(group, "apply_quality", c)
	tier_changed.emit(tier)


func cycle() -> void:
	set_tier((tier + 1) % PRESETS.size())
