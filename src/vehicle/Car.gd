class_name Car
extends VehicleBody3D
## A drivable Shanghai car. Chaos-vehicle equivalent: Godot's built-in raycast vehicle,
## which gives real suspension, weight transfer and understeer without an authored model.

const WHEEL_OFFS := [
	Vector3(0.86, 0.36, 1.42), Vector3(-0.86, 0.36, 1.42),
	Vector3(0.90, 0.36, -1.38), Vector3(-0.90, 0.36, -1.38),
]

var wheels: Array[VehicleWheel3D] = []
var wheel_visuals: Array[MeshInstance3D] = []
var cam: Camera3D
var cam_arm: SpringArm3D
var headlights: Array[OmniLight3D] = []
var body_mesh: MeshInstance3D
var driving: bool = false
var top_speed_kmh: float = 190.0
var steering_smooth: float = 0.0
var engine_note: float = 0.0
var _wheel_spin: float = 0.0
var _air_time: float = 0.0


func _ready() -> void:
	add_to_group("car")
	mass = 1450.0
	# Parked cars must not shove the avatar around while nobody is driving them.
	freeze = true
	_build_chassis()
	_build_wheels()
	_build_camera()
	_build_lights()


func _build_chassis() -> void:
	var paint: Color = [Color(0.72, 0.73, 0.75), Color(0.09, 0.10, 0.12), Color(0.34, 0.05, 0.05),
		Color(0.05, 0.13, 0.30), Color(0.86, 0.79, 0.20)][int(GameGlobals.rng.randf() * 5.0) % 5]
	var shell := StandardMaterial3D.new()
	shell.albedo_color = paint
	shell.metallic = 0.55
	shell.metallic_specular = 0.7
	shell.roughness = lerpf(0.20, 0.42, GameGlobals.rng.randf())
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.04, 0.05, 0.07)
	glass.roughness = 0.06
	glass.metallic = 0.1
	glass.metallic_specular = 1.0

	var f := MeshFusion.new()
	var hull := Color(0, 0, 0)
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 0.46, 0.0)), Vector3(1.86, 0.62, 4.42), hull)
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 1.02, -0.12)), Vector3(1.62, 0.52, 2.16), hull)
	f.box(Transform3D(Basis.IDENTITY, Vector3(0, 0.30, 0.0)), Vector3(1.70, 0.30, 4.20), hull)
	body_mesh = MeshInstance3D.new()
	body_mesh.mesh = f.commit()
	body_mesh.material_overlay = shell
	add_child(body_mesh)

	var g := MeshFusion.new()
	g.box(Transform3D(Basis.IDENTITY, Vector3(0, 1.03, -0.13)), Vector3(1.58, 0.46, 2.10), hull)
	var gm := MeshInstance3D.new()
	gm.mesh = g.commit()
	gm.material_overlay = glass
	add_child(gm)

	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.9, 1.35, 4.5)
	cs.position = Vector3(0, 0.78, 0)
	cs.shape = shape
	add_child(cs)


func _build_wheels() -> void:
	var tyre := StandardMaterial3D.new()
	tyre.albedo_color = Color(0.045, 0.045, 0.048)
	tyre.roughness = 0.92
	var rim := StandardMaterial3D.new()
	rim.albedo_color = Color(0.52, 0.53, 0.56)
	rim.metallic = 0.9
	rim.roughness = 0.32
	for i in WHEEL_OFFS.size():
		var w := VehicleWheel3D.new()
		w.position = WHEEL_OFFS[i]
		w.wheel_rest_length = 0.30
		w.wheel_radius = 0.36
		w.suspension_travel = 0.24
		w.suspension_stiffness = 42.0
		w.suspension_max_force = 14000.0
		w.damping_compression = 0.30
		w.damping_relaxation = 0.34
		w.wheel_friction_slip = 10.5
		w.wheel_roll_influence = 0.14
		# Front axle steers, rear axle drives — a conventional Shanghai saloon.
		w.use_as_steering = i < 2
		w.use_as_traction = i >= 2
		add_child(w)
		wheels.append(w)
		var mi := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.24
		torus.outer_radius = 0.365
		torus.rings = 12
		torus.ring_segments = 12
		mi.mesh = torus
		mi.material_overlay = tyre
		mi.rotation.y = PI * 0.5
		var hub := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.235
		cm.bottom_radius = 0.235
		cm.height = 0.30
		cm.radial_segments = 10
		hub.mesh = cm
		hub.material_overlay = rim
		hub.rotation.z = PI * 0.5
		mi.add_child(hub)
		add_child(mi)
		wheel_visuals.append(mi)


func _build_camera() -> void:
	cam_arm = SpringArm3D.new()
	cam_arm.spring_length = 5.4
	cam_arm.position = Vector3(0, 1.85, -0.4)
	cam_arm.rotation.x = -0.16
	cam_arm.collision_mask = 1
	add_child(cam_arm)
	cam = Camera3D.new()
	cam.fov = 66.0
	cam.near = 0.18
	cam.far = 3600.0
	cam.add_to_group("camera")
	cam_arm.add_child(cam)


func _build_lights() -> void:
	for s in [-1, 1]:
		var l := OmniLight3D.new()
		l.position = Vector3(0.66 * s, 0.72, 2.1)
		l.omni_range = 34.0
		l.light_energy = 0.0
		l.light_color = Color(0.92, 0.96, 1.0)
		add_child(l)
		headlights.append(l)


func apply_quality(c: Dictionary) -> void:
	if cam != null:
		cam.far = float(c["camera_far"])
		get_window().scaling_3d_scale = float(c["scale"])


func _physics_process(delta: float) -> void:
	if driving:
		var steer_in := Input.get_axis("move_left", "move_right")
		var throttle := 0.0
		if Input.is_action_pressed("move_forward"):
			throttle = 1.0
		if Input.is_action_pressed("move_back"):
			throttle = -1.0
		var kmh := linear_velocity.length() * 3.6
		# Speed-limited throttle keeps the car usable without a full engine curve.
		var limit := 1.0 - clampf(kmh / top_speed_kmh, 0.0, 1.0)
		engine_force = throttle * 9800.0 * limit * (1.0 if throttle > 0.0 else 1.6)
		var target_steer := steer_in * 0.62 * clampf(1.0 - kmh / 210.0, 0.28, 1.0)
		steering_smooth = move_toward(steering_smooth, target_steer, delta * 3.4)
		steering = steering_smooth
		brake = 14.0 if Input.is_action_pressed("handbrake") else 0.0
		if brake > 0.5:
			engine_force = 0.0
		# Suspension load feeds a believable body roll into the visuals.
		_roll_visual(delta)
	else:
		engine_force = 0.0
		steering = move_toward(steering, 0.0, delta * 2.0)
		brake = 14.0
	# Recover if the car ends up on its roof or under the map.
	if global_position.y < -6.0 or rotation_degrees.x > 60.0 or rotation_degrees.x < -60.0:
		_air_time += delta
		if _air_time > 1.2:
			reset_upright()
	else:
		_air_time = 0.0
	_wheel_spin -= linear_velocity.length() * delta / 0.36
	for i in wheels.size():
		var w: VehicleWheel3D = wheels[i]
		var mi: MeshInstance3D = wheel_visuals[i]
		mi.position = w.position
		# VehicleWheel3D's own `rotation` is shadowed by Node3D.rotation, so wheel spin is
		# integrated from ground speed instead.
		mi.rotation.x = _wheel_spin
		if i < 2:
			mi.rotation.y = steering_smooth


func _roll_visual(delta: float) -> void:
	if body_mesh == null:
		return
	var local: float = (global_transform.basis.inverse() * linear_velocity).x
	var want := clampf(-local * 0.012, -0.09, 0.09)
	body_mesh.rotation.z = move_toward(body_mesh.rotation.z, want, delta * 5.0)
	# Brake squats the nose under heavy deceleration.
	engine_note = move_toward(engine_note, clampf(absf(engine_force) / 9800.0, 0.0, 1.0), delta * 3.0)
	body_mesh.position.z = move_toward(body_mesh.position.z, -engine_note * 0.05, delta * 5.0)


func reset_upright() -> void:
	global_transform = Transform3D(Basis.IDENTITY.rotated(Vector3.UP, yaw_of()),
		Vector3(global_position.x, 2.4, global_position.z))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	GameGlobals.say("车辆已复位")


func yaw_of() -> float:
	var f := -global_transform.basis.z
	return atan2(f.x, f.z)


func set_headlights(on: bool) -> void:
	for l in headlights:
		l.light_energy = 4.5 if on else 0.0


func speed_kmh() -> float:
	return linear_velocity.length() * 3.6
