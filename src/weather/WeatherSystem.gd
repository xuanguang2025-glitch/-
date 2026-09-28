class_name WeatherSystem
extends Node3D
## GPU particle precipitation that follows the camera rather than the world. Rain is a
## fixed-volume tube centred on the viewer, which is the only way to keep a downpour cheap
## over a 12 km map — the alternative is per-chunk emitters that pop as you drive.

const RAIN_BOX := Vector3(150.0, 70.0, 150.0)

var rain: GPUParticles3D
var splash: GPUParticles3D
var particle_scale := 1.0
var _kind := 0
var _intensity := 0.0
var _wind := Vector3.ZERO


func _ready() -> void:
	add_to_group("weather")
	rain = _make_rain()
	add_child(rain)
	GameGlobals.weather_changed.connect(_on_weather)


func apply_quality(c: Dictionary) -> void:
	particle_scale = float(c["particle_scale"])
	_configure()


func _make_rain() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.lifetime = 1.1
	p.preprocess = 1.1
	p.local_coords = false
	p.visibility_aabb = AABB(-RAIN_BOX * 0.5, RAIN_BOX)
	# draw_pass_1 takes a Mesh directly; the material goes on the particles node.
	var bm := BoxMesh.new()
	bm.size = Vector3(0.035, 1.35, 0.035)
	p.draw_pass_1 = bm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.72, 0.80, 0.92, 0.42)
	p.material_overlay = m
	var proc := ParticleProcessMaterial.new()
	proc.direction = Vector3(0, -1, 0)
	proc.spread = 3.0
	proc.initial_velocity_min = 46.0
	proc.initial_velocity_max = 68.0
	proc.gravity = Vector3(0, -18.0, 0)
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = RAIN_BOX * 0.5
	p.process_material = proc
	return p


func _on_weather(kind: int, intensity: float) -> void:
	_kind = kind
	_intensity = intensity
	_configure()


func _configure() -> void:
	var amount := 0
	var vel_min := 46.0
	var vel_max := 68.0
	var stretch := 1.35
	_wind = Vector3.ZERO
	match _kind:
		GameGlobals.Weather.RAIN:
			amount = int(2600 * _intensity)
		GameGlobals.Weather.STORM:
			amount = int(6200 * _intensity)
			vel_min = 62.0
			vel_max = 88.0
			stretch = 1.9
			_wind = Vector3(9.0, 0, 4.0)
		GameGlobals.Weather.TYPHOON:
			amount = int(9000 * _intensity)
			vel_min = 78.0
			vel_max = 104.0
			stretch = 2.6
			_wind = Vector3(22.0, 0, 9.0)
		_:
			amount = 0
	# Godot requires amount >= 1 and trail_lifetime >= 0.01, so dry weather keeps the node
	# alive with one dormant particle and simply stops emitting.
	var n := maxi(int(amount * particle_scale), 1)
	rain.amount = n
	rain.emitting = amount > 0
	rain.trail_enabled = amount > 0
	if amount > 0:
		rain.trail_lifetime = 0.14
	var proc := rain.process_material as ParticleProcessMaterial
	if proc != null:
		proc.initial_velocity_min = vel_min
		proc.initial_velocity_max = vel_max
		proc.gravity = Vector3(_wind.x, -18.0, _wind.z)
		if proc.spread > 0.0:
			proc.spread = 3.0 if _kind != GameGlobals.Weather.TYPHOON else 16.0
	var bm := rain.draw_pass_1 as BoxMesh
	if bm != null:
		bm.size = Vector3(0.035, stretch, 0.035)


## Keep the precipitation tube centred on whatever the player is looking at.
func follow(cam_pos: Vector3) -> void:
	global_position = Vector3(cam_pos.x, cam_pos.y + 26.0, cam_pos.z)


func intensity_now() -> float:
	return _intensity
