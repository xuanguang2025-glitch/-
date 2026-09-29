class_name RemoteAvatarLayer
extends Node3D
## Phase 177 / 178: turn replicated entity state into something a player can actually see.
##
## Until this existed the multiplayer claim was "the server's state is mutually knowable": the
## client stored every remote position in `remote_entities` and rendered none of it. Storing
## without presenting is not "two players see each other", so this layer is what closes that.
##
## Positions are smoothed rather than assigned. The server replicates at 30 Hz; snapping a node to
## each packet makes a walking player look like they are teleporting three times per tenth-second,
## which is the exact failure Phase 177 names. A large gap is snapped instead of glided, because a
## glide after a teleport or a respawn reads as a flying person.
##
## Height is not replicated — the server sends x/z/yaw only — so avatars stand on the ground plane.
## That is a real limitation, recorded in KNOWN_ISSUES, not something to hide by guessing a Y.

const SMOOTH_RATE := 14.0		# per-second exponential approach to the replicated position
const SNAP_DISTANCE := 30.0		# metres of gap beyond which smoothing would look like flight

var client: MultiplayerClient

var _avatars: Dictionary = {}	# entity id -> Node3D
var _targets: Dictionary = {}	# entity id -> Vector3


func bind(c: MultiplayerClient) -> void:
	client = c


func avatar_count() -> int:
	return _avatars.size()


func avatar_of(id: String) -> Node3D:
	return _avatars.get(id) as Node3D


func _process(delta: float) -> void:
	if client == null:
		return
	var live: Dictionary = client.remote_entities
	for eid in live:
		var e: Dictionary = live[eid]
		var target := Vector3(float(e.get("x", 0.0)), 0.05, float(e.get("z", 0.0)))
		var node: Node3D = _avatars.get(eid)
		if node == null:
			node = _build(String(e.get("kind", "player")))
			_avatars[eid] = node
			_targets[eid] = target
			node.position = target
		else:
			var prev: Vector3 = _targets.get(eid, target)
			if prev.distance_to(target) > SNAP_DISTANCE:
				node.position = target
			else:
				var w := clampf(SMOOTH_RATE * delta, 0.0, 1.0)
				node.position = node.position.lerp(target, w)
			_targets[eid] = target
		node.rotation.y = float(e.get("yaw", 0.0))
	for eid in _avatars.keys():
		if not live.has(eid):
			var gone: Node3D = _avatars[eid]
			_avatars.erase(eid)
			_targets.erase(eid)
			gone.queue_free()


func _build(kind: String) -> Node3D:
	var root := Node3D.new()
	var skin := StandardMaterial3D.new()
	# Deliberately not the local player's slate: a remote body has no nameplate yet, so colour is
	# the only thing that says "that is someone else".
	skin.albedo_color = Color(0.72, 0.34, 0.20) if kind == "player" else Color(0.35, 0.45, 0.62)
	skin.roughness = 0.7
	var torso := MeshInstance3D.new()
	var tm := CapsuleMesh.new()
	tm.radius = 0.28
	tm.height = 0.92
	torso.mesh = tm
	torso.material_overlay = skin
	torso.position = Vector3(0, 1.06, 0)
	root.add_child(torso)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.145
	hm.height = 0.29
	hm.radial_segments = 12
	hm.rings = 8
	head.mesh = hm
	head.material_overlay = skin
	head.position = Vector3(0, 1.60, 0)
	root.add_child(head)
	add_child(root)
	return root
