class_name QuestMount
extends RefCounted
## One composition seam for the gameplay layer, for the same reason `LifeMount` exists: GameRoot
## is pinned against the 900-line ceiling, and a quest giver is four statements (node, mesh,
## registration, binding) that belong to assembly rather than to the quest rules.
##
## The giver is a stationary pedestrian built from the crowd's own body mesh, not a bespoke
## capsule: a quest NPC that does not look like the other pedestrians is the kind of thing that
## reads as a placeholder even when every rule behind it works.

static func mount(parent: Node, sim: CitySim, spawn: Vector2, yaw: float) -> QuestSystem:
	var quests := QuestSystem.new()
	quests.name = "QuestSystem"
	parent.add_child(quests)

	var inter := InteractionSystem.new()
	inter.name = "InteractionSystem"
	parent.add_child(inter)

	quests.attach(sim)
	inter.quests = quests
	inter.bind_player(_player(parent))

	var spot := _giver_spot(spawn, yaw)
	quests.giver_pos = spot
	print("[quest] giver=%s 交互半径 %.1f m" % [str(spot), InteractionSystem.REACH])
	_spawn_giver(parent, quests, inter, spot, yaw)
	return quests


static func _player(parent: Node) -> Node3D:
	if parent != null and parent.is_inside_tree():
		return parent.get_tree().get_first_node_in_group("player") as Node3D
	return null


## Somewhere a person could actually stand: not inside a building, not in the river. The giver is
## placed *relative to the resolved spawn*, because the spawn search moves the player — a fixed
## coordinate put the only quest in the city 57 m away from wherever the player actually appeared,
## which is the same as not having a quest giver.
static func _giver_spot(spawn: Vector2, yaw: float) -> Vector2:
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	# 2.2 m, not 3.0: the player settles a little off the exact spawn point after physics, and at
	# 3.0 the measured distance came out 3.5 m — outside the 3.4 m reach, so the prompt never
	# appeared and the only quest in the city was unreachable from where you start.
	var ideal := spawn + fwd * 2.2
	if _standable(ideal):
		return ideal
	for r in range(4, 40, 3):
		for i in 12:
			var a := TAU * float(i) / 12.0
			var p := spawn + Vector2(cos(a), sin(a)) * float(r)
			if _standable(p):
				return p
	return spawn


static func _standable(p: Vector2) -> bool:
	if CityData.in_water(p):
		return false
	if CityData.blocks_building(p, 1.0):
		return false
	return true


static func _spawn_giver(parent: Node, quests: QuestSystem, inter: InteractionSystem,
		spot: Vector2, yaw: float) -> void:
	var body := Node3D.new()
	body.name = "QuestGiver"
	# Facing the player at spawn: a person staring at a fixed compass direction is the cheapest
	# way to make an NPC read as scenery.
	body.rotation.y = yaw + PI
	var mi := MeshInstance3D.new()
	mi.mesh = CrowdSystem._human_mesh(0)
	mi.material_override = Assets.props_mat(false)
	body.add_child(mi)
	parent.add_child(body)
	# The streamed ground's height at this point, the same function everything else places with —
	# assuming y = 0 is what leaves an NPC's feet buried on the riverbank slope.
	body.position = Vector3(spot.x, CityData.terrain_y(spot), spot.y)

	inter.register("quest_giver", "老周", "npc", spot, ["交谈"], Callable(), 5)
	inter.handlers["quest_giver"] = func() -> void:
		var inst := quests.instance("side_bund_01")
		if String(inst.get("state", "")) == "Available":
			quests.accept("side_bund_01")
			GameGlobals.hud_message.emit("接取任务：外滩三件事", 3.0)
		elif String(inst.get("state", "")) == "InProgress":
			quests.on_interact("quest_giver")
		elif String(inst.get("state", "")) == "Completed":
			GameGlobals.hud_message.emit("老周：多谢，路上慢点。", 3.0)
		else:
			GameGlobals.hud_message.emit("老周：这会儿不方便。", 2.0)


## The live layer, found the way the crowd finds the economy: by group. A world with no quest
## layer yields null, and callers say so instead of reporting an empty pass.
static func of(tree: SceneTree) -> QuestSystem:
	if tree == null:
		return null
	return tree.get_first_node_in_group("quests") as QuestSystem
