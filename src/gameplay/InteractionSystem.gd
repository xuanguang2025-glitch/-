class_name InteractionSystem
extends Node
## Phase 345: one interaction entry point, and the rule that makes it trustworthy — a legal
## action is decided in logic, not by whether the HUD drew a button.
##
## `nearest()` is what the prompt uses; `activate()` re-derives range and conditions from the
## player's live position before it does anything. A caller that skips the prompt and calls
## `activate()` from across the map gets a refusal, which is the only version of this interface
## that survives a UI bug.

signal interacted(interaction_id: String, kind: String)
signal refused(interaction_id: String, why: String)

## Arm's length. A conversation across a six-lane road is not a conversation.
const REACH := 3.4
const SAMPLE_STEP := 0.25

var quests: QuestSystem
var handlers: Dictionary = {}		# interaction_id -> Callable, for objects that do more than talk
var last_refusal := ""
var _items: Dictionary = {}		# interaction_id -> record
var _player: Node3D
var _sample_t := 0.0
var _last_p := Vector2.INF


func _ready() -> void:
	add_to_group("interactions")
	set_process(true)


func bind_player(p: Node3D) -> void:
	_player = p


## Registers an interactable. `conditions` is a Callable returning "" when allowed, or the reason
## it is not — the same shape QuestDefs.validate uses, so failures read the same everywhere.
func register(id: String, name: String, kind: String, pos: Vector2, actions: Array,
		conditions := Callable(), priority := 0) -> void:
	_items[id] = {
		"id": id, "name": name, "kind": kind, "pos": pos,
		"actions": actions, "conditions": conditions, "priority": priority,
	}


func unregister(id: String) -> void:
	_items.erase(id)


func count() -> int:
	return _items.size()


func item(id: String) -> Dictionary:
	return _items.get(id, {})


func player_pos() -> Vector2:
	# Lazy, not cached at bind time: the quest layer is mounted from GameRoot's _ready, and the
	# player joins the "player" group later in that same frame. Binding once left `_player` null
	# for the entire session, which made every interaction answer "找不到玩家" — a failure the
	# self-test caught on the first run, but only because it exercised activate() directly.
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
	if _player != null:
		return Vector2(_player.global_position.x, _player.global_position.z)
	return Vector2.INF


## Closest interactable inside reach, or {} when there is none. Priority breaks ties, then
## distance — so a quest item lying on a shop counter beats the shop's door.
func nearest() -> Dictionary:
	var p := player_pos()
	if p == Vector2.INF:
		return {}
	var best: Dictionary = {}
	var best_d := INF
	for id in _items:
		var it: Dictionary = _items[id]
		var d: float = p.distance_to(it["pos"])
		if d > REACH:
			continue
		var cond: Callable = it["conditions"]
		if cond.is_valid() and String(cond.call()) != "":
			continue
		if best.is_empty() or int(it["priority"]) > int(best["priority"]) \
				or (int(it["priority"]) == int(best["priority"]) and d < best_d):
			best = it
			best_d = d
	return best


## The authorisation path. Returns false and records `why` when the action is not legal *now*.
func activate(id: String) -> bool:
	var it: Dictionary = _items.get(id, {})
	if it.is_empty():
		return _deny(id, "没有这个交互对象")
	var p := player_pos()
	if p == Vector2.INF:
		return _deny(id, "找不到玩家，无法校验距离")
	var d: float = p.distance_to(it["pos"])
	if d > REACH:
		return _deny(id, "距离 %.1f m 超出交互范围 %.1f m" % [d, REACH])
	var cond: Callable = it["conditions"]
	if cond.is_valid():
		var why := String(cond.call())
		if why != "":
			return _deny(id, why)
	interacted.emit(id, String(it["kind"]))
	# A registered handler owns the consequences; only a plain NPC falls through to "counts as a
	# conversation". Both paths run *after* the distance and condition checks above, so there is
	# no route from a prompt to an effect that skips authorisation.
	if handlers.has(id):
		(handlers[id] as Callable).call()
	elif quests != null and String(it["kind"]) == "npc":
		quests.on_interact(id)
	return true


func _deny(id: String, why: String) -> bool:
	last_refusal = why
	refused.emit(id, why)
	return false


func _process(delta: float) -> void:
	# E, not an InputMap action, because adding an action means editing project.godot's input
	# section and this system must stay mountable without a project settings migration.
	_sample_t += delta
	if _sample_t < SAMPLE_STEP:
		return
	_sample_t = 0.0
	var p := player_pos()
	if p == Vector2.INF:
		return
	# Only tell the quest layer when the player has actually gone somewhere; a standing player
	# produces no events at all.
	if _last_p == Vector2.INF or p.distance_to(_last_p) > 2.0:
		_last_p = p
		if quests != null:
			quests.on_player_moved(p)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if (event as InputEventKey).keycode != KEY_E:
		return
	var it := nearest()
	if it.is_empty():
		return
	if activate(String(it["id"])):
		get_viewport().set_input_as_handled()
