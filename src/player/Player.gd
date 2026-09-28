class_name Player
extends CharacterBody3D
## Third-person avatar with a walk/run/jump controller, a spring-arm camera that also does
## first-person, and a soft refusal to let you stroll into the Huangpu.

signal camera_moved(pos: Vector3)

const STEP_UP := 0.42

var cam_pivot: Node3D
var spring: SpringArm3D
var camera: Camera3D
var yaw: float = 0.0
var pitch: float = -0.12
var first_person: bool = false
var fly: bool = false
var body: MeshInstance3D
var head: MeshInstance3D
var interact_target: Node = null
var _speed_ratio: float = 0.0
var _bob: float = 0.0
var _last_land: Vector3 = Vector3.ZERO

@export var move_scale: float = 1.0


func _ready() -> void:
	collision_layer = 4
	collision_mask = 1 | 2
	add_to_group("player")
	_build_collision()
	_build_body()
	_build_camera()
	_last_land = position


func _build_collision() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.34
	cap.height = 1.78
	cs.shape = cap
	cs.position = Vector3(0, 0.89, 0)
	add_child(cs)


func _build_body() -> void:
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.30, 0.32, 0.38)
	skin.roughness = 0.72
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.10, 0.11, 0.14)
	dark.roughness = 0.8
	body = MeshInstance3D.new()
	var torso := CapsuleMesh.new()
	torso.radius = 0.28
	torso.height = 0.92
	body.mesh = torso
	body.material_overlay = skin
	body.position = Vector3(0, 1.06, 0)
	add_child(body)
	head = MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.145
	hm.height = 0.29
	hm.radial_segments = 12
	hm.rings = 8
	head.mesh = hm
	head.material_overlay = dark
	head.position = Vector3(0, 1.60, 0)
	add_child(head)
	for s in [-1, 1]:
		var arm := MeshInstance3D.new()
		var am := CapsuleMesh.new()
		am.radius = 0.075
		am.height = 0.62
		arm.mesh = am
		arm.material_overlay = dark
		arm.position = Vector3(0.34 * s, 1.08, 0)
		add_child(arm)
		var leg := MeshInstance3D.new()
		var lm := CapsuleMesh.new()
		lm.radius = 0.10
		lm.height = 0.80
		leg.mesh = lm
		leg.material_overlay = dark
		leg.position = Vector3(0.14 * s, 0.42, 0)
		leg.name = "leg_%d" % s
		add_child(leg)


func _build_camera() -> void:
	cam_pivot = Node3D.new()
	add_child(cam_pivot)
	spring = SpringArm3D.new()
	spring.spring_length = 5.2
	spring.position = Vector3(0, 1.42, 0)
	spring.margin = 0.32
	spring.collision_mask = 1 | 2
	cam_pivot.add_child(spring)
	camera = Camera3D.new()
	camera.fov = 62.0
	camera.near = 0.16
	camera.far = 3600.0
	camera.current = true
	camera.add_to_group("camera")
	spring.add_child(camera)
	RenderingServer.set_debug_generate_wireframes(false)


func apply_quality(c: Dictionary) -> void:
	if camera == null:
		return
	camera.far = float(c["camera_far"])
	camera.scaling_3d_scale = float(c["scale"])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var rel: Vector2 = event.relative
		yaw -= rel.x * 0.0026
		pitch = clampf(pitch - rel.y * 0.0022, -1.32, 1.12)
		cam_pivot.rotation.y = yaw
		spring.rotation.x = pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and GameGlobals.is_playing():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_C:
		first_person = not first_person
		GameGlobals.say("视角：%s" % ("第一人称" if first_person else "第三人称"))


func _physics_process(delta: float) -> void:
	if not is_inside_tree():
		return
	var mode := GameGlobals.game_mode
	if mode == GameGlobals.GameMode.DRIVE:
		hide_body()
		velocity = Vector3.ZERO
		return
	show_body()

	if not is_on_floor():
		velocity.y -= GameGlobals.GRAVITY * delta
	else:
		velocity.y = maxf(velocity.y, -0.5)

	if fly:
		_fly(delta)
		return

	var iv := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var input := Vector3(iv.x, 0.0, iv.y)
	input = input.rotated(Vector3.UP, yaw)
	var running := Input.is_action_pressed("sprint")
	var target: float = GameGlobals.PLAYER_SPEED_WALK
	if running:
		target = GameGlobals.PLAYER_SPEED_SPRINT
	elif iv.length_squared() > 0.02:
		target = GameGlobals.PLAYER_SPEED_RUN
	target *= move_scale
	_speed_ratio = clampf(Vector3(velocity.x, 0.0, velocity.z).length() / GameGlobals.PLAYER_SPEED_SPRINT, 0.0, 1.0)
	velocity.x = move_toward(velocity.x, input.x * target, 26.0 * delta)
	velocity.z = move_toward(velocity.z, input.z * target, 26.0 * delta)
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = GameGlobals.PLAYER_JUMP
	# Crouch drops the camera pivot rather than the capsule.
	if Input.is_action_just_pressed("crouch"):
		spring.position.y = 0.72 if spring.position.y > 1.0 else 1.42

	if iv.length_squared() > 0.02:
		rotation.y = lerp_angle(rotation.y, atan2(input.x, input.z), clampf(delta * 12.0, 0.0, 1.0))
		_bob += delta * (10.0 + _speed_ratio * 8.0)
		var lean := sin(_bob) * 0.045 * (0.4 + _speed_ratio)
		if has_node("leg_-1"):
			get_node("leg_-1").rotation.x = lean * 6.0
			get_node("leg_1").rotation.x = -lean * 6.0
		body.rotation.x = clampf(_speed_ratio * 0.22, 0.0, 0.22)

	var want := global_position + velocity * delta
	if CityData.in_water(Vector2(want.x, want.z)):
		velocity.x *= 0.05
		velocity.z *= 0.05
		GameGlobals.say("黄浦江 — 请勿下水", 1.2)
	move_and_slide()
	# The drawn riverbed is 14 m below the flat collision plane, so letting the avatar rest
	# in the channel reads as sinking through the water. Pin them to the last bank position.
	var here := Vector2(global_position.x, global_position.z)
	if CityData.in_water(here):
		global_position = _last_land
		velocity = Vector3.ZERO
	else:
		_last_land = global_position
	_slide_out_of_geometry()
	camera_moved.emit(global_position)


func _fly(delta: float) -> void:
	var iv := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := Vector3(iv.x, 0.0, iv.y).rotated(Vector3.UP, yaw)
	var up := 0.0
	if Input.is_action_pressed("fly_up"):
		up += 1.0
	if Input.is_action_pressed("fly_down"):
		up -= 1.0
	var sp := 46.0 if Input.is_action_pressed("sprint") else 16.0
	velocity = Vector3(dir.x * sp, up * sp * 0.7, dir.z * sp)
	global_position += velocity * delta
	velocity = Vector3.ZERO


func _slide_out_of_geometry() -> void:
	# Buildings are merged boxes; nudge the avatar clear of any it ends up inside of after
	# a stream load, which is the standard open-world respawn-guard.
	var here := global_position
	if CityData.blocks_building(Vector2(here.x, here.z), 1.2) and is_on_floor():
		global_position = Vector3(here.x, here.y + 0.2, here.z)


func hide_body() -> void:
	body.visible = false
	head.visible = false
	for c in get_children():
		if c is MeshInstance3D:
			c.visible = false
	camera.current = false


func show_body() -> void:
	for c in get_children():
		if c is MeshInstance3D and c != null:
			c.visible = true
	if camera != null and not camera.current and GameGlobals.game_mode != GameGlobals.GameMode.DRIVE:
		camera.current = true


func camera_position() -> Vector3:
	if camera == null:
		return global_position
	return camera.global_position


func speed_ratio() -> float:
	return _speed_ratio
