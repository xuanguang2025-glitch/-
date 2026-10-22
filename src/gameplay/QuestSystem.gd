class_name QuestSystem
extends Node
## Phase 346 / 347 / 349 / 353 / 359: one quest, one state machine, one reward, one save file.
##
## The scope is deliberately the spec's "第一阶段：最小可玩闭环" rather than a framework. What
## exists here is exactly what a player can reach: accept a side quest from one NPC, drive three
## objectives from real events, get paid out of the ledger, and still have the progress after a
## restart.
##
## Three rules that shaped the code:
##
##   1. **Progress is pushed, never polled.** The giver calls `on_interact`; the world calls
##      `on_player_moved`. Nothing here iterates the city, and no objective re-reads the world.
##   2. **Illegal transitions are refused with a reason.** `last_error` is the failure record the
##      spec asks for; a silent `return` would make "the quest is stuck" impossible to diagnose.
##   3. **Rewards are booked into the ledger, not printed.** `credit_wage` moves cents from the
##      district's housing bucket into its resident bucket, so `money_total()` is unchanged by a
##      reward — a quest cannot mint money, which is the only claim that makes the payout real.
##
## Reward idempotency is a flag on the instance plus a monotonic `revision`, not a hope: a second
## `complete()` is refused by the state machine before the payout line is reached.

signal quest_changed(quest_id: String)
signal reward_paid(quest_id: String, cents: int)

const SAVE_PATH := "user://quests.json"
const SAVE_SCHEMA := 1

## Overridable so the self-test does not write over the player's progress. Running `--sim-test`
## on a real install used to save a half-finished quest into the same file the game loads at
## boot, which meant "test the build" quietly edited your save.
var save_path := SAVE_PATH

const STATES := ["Locked", "Available", "Accepted", "InProgress", "Completed", "Failed",
	"Abandoned"]

## Phase 346: "必须明确每种状态的合法转换". Everything not listed here is refused.
const LEGAL := {
	"Locked": ["Available"],
	"Available": ["Accepted", "Locked"],
	"Accepted": ["InProgress", "Failed", "Abandoned"],
	"InProgress": ["Completed", "Failed", "Abandoned"],
	"Completed": [],
	"Failed": ["Available"],
	"Abandoned": ["Available"],
}

var sim: CitySim
var giver_npc := "quest_giver"
var giver_pos := Vector2.INF

var instances: Dictionary = {}		# quest_id -> instance Dictionary
var active_id := ""
var last_error := ""
var revision := 0


func _ready() -> void:
	add_to_group("quests")
	_bootstrap_instances()


# --- Lifecycle --------------------------------------------------------------
func attach(city: CitySim) -> void:
	sim = city
	load_progress()


func _bootstrap_instances() -> void:
	for id in QuestDefs.ids():
		var def := QuestDefs.get_def(id)
		var reason := QuestDefs.validate(def)
		if reason != "":
			# Pushed, not ignored: a broken definition must be visible at boot, otherwise the
			# NPC offers a quest that can never be finished.
			push_warning("[quest] 定义不可发布 %s：%s" % [id, reason])
			continue
		if instances.has(id):
			continue
		instances[id] = {
			"quest_id": id,
			"state": "Available" if (def.get("prerequisites", []) as Array).is_empty() else "Locked",
			"objectives": _blank_objectives(def),
			"accepted_at": 0,
			"completed_at": 0,
			"revision": 0,
			"reward_claimed": false,
			"failed_reason": "",
		}


static func _blank_objectives(def: Dictionary) -> Dictionary:
	var out := {}
	for o in def.get("objectives", []):
		out[String(o["id"])] = {"done": false, "amount": 0}
	return out


func instance(id: String) -> Dictionary:
	return instances.get(id, {})


func def_of(id: String) -> Dictionary:
	return QuestDefs.get_def(id)


func active() -> Dictionary:
	return instance(active_id) if not active_id.is_empty() else {}


# --- State machine ----------------------------------------------------------
func accept(id: String) -> bool:
	var inst := instance(id)
	if inst.is_empty():
		return _refuse("任务不存在：%s" % id)
	var def := def_of(id)
	var reason := QuestDefs.validate(def)
	if reason != "":
		return _refuse("任务定义不可发布：%s" % reason)
	if not _can(String(inst["state"]), "Accepted"):
		return _refuse("%s 不能从 %s 转到 Accepted" % [id, inst["state"]])
	if not _prereqs_met(def):
		return _refuse("前置任务未完成")
	inst["state"] = "Accepted"
	inst["accepted_at"] = Time.get_unix_time_from_system()
	_bump(id, inst)
	active_id = id
	# Accepted -> InProgress is a real transition, not bookkeeping: before this point the player
	# holds a contract; after it the objectives are live and will accept events.
	inst["state"] = "InProgress"
	_bump(id, inst)
	return true


func abandon(id: String) -> bool:
	var inst := instance(id)
	if inst.is_empty():
		return _refuse("任务不存在：%s" % id)
	if not _can(String(inst["state"]), "Abandoned"):
		return _refuse("%s 不能从 %s 放弃" % [id, inst["state"]])
	inst["state"] = "Abandoned"
	inst["objectives"] = _blank_objectives(def_of(id))
	_bump(id, inst)
	if active_id == id:
		active_id = ""
	return true


func fail(id: String, reason: String) -> bool:
	var inst := instance(id)
	if inst.is_empty():
		return _refuse("任务不存在：%s" % id)
	if not _can(String(inst["state"]), "Failed"):
		return _refuse("%s 不能从 %s 判失败" % [id, inst["state"]])
	inst["state"] = "Failed"
	inst["failed_reason"] = reason
	_bump(id, inst)
	if active_id == id:
		active_id = ""
	return true


# --- Event intake -----------------------------------------------------------
## The player interacted with `npc`. Only objectives that name this NPC move.
func on_interact(npc: String) -> void:
	for id in instances.keys():
		var inst: Dictionary = instances[id]
		if String(inst["state"]) != "InProgress":
			continue
		for o in def_of(id).get("objectives", []):
			if String(o["kind"]) != "TalkToNPC":
				continue
			if String((o.get("params", {}) as Dictionary).get("npc", "")) != npc:
				continue
			_advance(id, String(o["id"]), 1)


## Called when the player has actually moved. Cheap by construction: it only measures distance to
## the active quest's place objectives, and it returns immediately when there is none.
func on_player_moved(p: Vector2) -> void:
	if active_id.is_empty():
		return
	var inst := instance(active_id)
	if String(inst.get("state", "")) != "InProgress":
		return
	for o in def_of(active_id).get("objectives", []):
		var kind := String(o["kind"])
		if kind != "ReachLocation" and kind != "VisitLandmark":
			continue
		var target := QuestDefs.objective_point(o)
		if target == Vector2.INF:
			continue
		var radius := float((o.get("params", {}) as Dictionary).get("radius", 20.0))
		if p.distance_to(target) <= radius:
			_advance(active_id, String(o["id"]), 1)


func _advance(id: String, objective_id: String, amount: int) -> bool:
	var inst := instance(id)
	if String(inst.get("state", "")) != "InProgress":
		return _refuse("只有进行中的任务能推进进度（%s 是 %s）" % [id, inst.get("state", "?")])
	var objs: Dictionary = inst["objectives"]
	if not objs.has(objective_id):
		return _refuse("任务 %s 没有目标 %s" % [id, objective_id])
	var rec: Dictionary = objs[objective_id]
	if bool(rec.get("done", false)):
		return true		# idempotent: re-entering the area must not double-count
	rec["amount"] = int(rec.get("amount", 0)) + amount
	rec["done"] = true
	_bump(id, inst)
	if _all_done(inst):
		return complete(id)
	return true


func _all_done(inst: Dictionary) -> bool:
	for k in (inst["objectives"] as Dictionary):
		if not bool((inst["objectives"] as Dictionary)[k].get("done", false)):
			return false
	return true


# --- Completion and reward --------------------------------------------------
func complete(id: String) -> bool:
	var inst := instance(id)
	if inst.is_empty():
		return _refuse("任务不存在：%s" % id)
	if String(inst["state"]) == "Completed":
		return _refuse("任务已结算，拒绝重复发奖")		# Phase 353: duplicate protection
	if not _can(String(inst["state"]), "Completed"):
		return _refuse("%s 不能从 %s 结算" % [id, inst["state"]])
	if not _all_done(inst):
		return _refuse("目标未全部完成，不能结算")
	inst["state"] = "Completed"
	inst["completed_at"] = Time.get_unix_time_from_system()
	_bump(id, inst)
	if active_id == id:
		active_id = ""
	var paid := _pay(id, def_of(id))
	inst["reward_claimed"] = true
	_bump(id, inst)
	save_progress()
	reward_paid.emit(id, paid)
	return true


## Returns the cents actually booked. `credit_wage` caps at what the district can fund, and the
## cap is reported rather than silently swallowed.
func _pay(id: String, def: Dictionary) -> int:
	var reward: Dictionary = def.get("reward", {})
	var cents := int(reward.get("cents", 0))
	if cents <= 0 or sim == null:
		return 0
	var dn := _player_district()
	var paid: int = sim.credit_wage(dn, cents)
	GameGlobals.hud_message.emit("任务完成：%s  +%.2f 元" % [String(def.get("title", id)),
		float(paid) / 100.0], 4.0)
	return paid


func _player_district() -> String:
	var p := _player_pos()
	if p == Vector2.INF:
		return String(sim.districts.keys()[0]) if not sim.districts.is_empty() else ""
	return String(CityData.district_at(p).get("name", ""))


func _player_pos() -> Vector2:
	var p := get_tree().get_first_node_in_group("player") as Node3D
	return Vector2(p.global_position.x, p.global_position.z) if p != null else Vector2.INF


# --- Save / load ------------------------------------------------------------
func save_progress() -> bool:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		last_error = "无法写入 %s（%s）" % [save_path, error_string(FileAccess.get_open_error())]
		return false
	f.store_string(JSON.stringify({
		"schema": SAVE_SCHEMA,
		"active_id": active_id,
		"instances": instances.values(),
	}, "\t"))
	f.close()
	return true


## Loads without replacing live state on failure. A corrupt file is reported, not treated as
## "no progress" — silently starting everyone over is the data loss the spec warns about.
func load_progress() -> bool:
	if not FileAccess.file_exists(save_path):
		return true
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		last_error = "无法读取 %s" % save_path
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "存档损坏：不是 JSON 对象"
		return false
	var doc: Dictionary = parsed
	if int(doc.get("schema", 0)) != SAVE_SCHEMA:
		last_error = "存档 schema 不匹配：%s" % str(doc.get("schema", "缺失"))
		return false
	for raw in doc.get("instances", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var rec: Dictionary = raw
		var id := String(rec.get("quest_id", ""))
		if not instances.has(id):
			continue		# unknown quest: dropped, not crashed on
		if not STATES.has(String(rec.get("state", ""))):
			continue
		instances[id] = rec
	active_id = String(doc.get("active_id", ""))
	if not instances.has(active_id):
		active_id = ""
	return true


func reset_for_test() -> void:
	instances.clear()
	active_id = ""
	last_error = ""
	_bootstrap_instances()


# --- Helpers ----------------------------------------------------------------
func _can(from: String, to: String) -> bool:
	return (LEGAL.get(from, []) as Array).has(to)


func _prereqs_met(def: Dictionary) -> bool:
	for q in def.get("prerequisites", []):
		var inst := instance(String(q))
		if inst.is_empty() or String(inst.get("state", "")) != "Completed":
			return false
	return true


func _bump(id: String, inst: Dictionary) -> void:
	revision += 1
	inst["revision"] = int(inst.get("revision", 0)) + 1
	quest_changed.emit(id)


func _refuse(reason: String) -> bool:
	last_error = reason
	return false


## One-line status for the HUD, and for the failure records the spec asks us to keep.
func status_line() -> String:
	if active_id.is_empty():
		return "任务：无"
	var def := def_of(active_id)
	var inst := instance(active_id)
	var parts: PackedStringArray = []
	for o in def.get("objectives", []):
		var rec: Dictionary = (inst["objectives"] as Dictionary).get(String(o["id"]), {})
		parts.append("%s%s" % ["✓" if bool(rec.get("done", false)) else "·", String(o["label"])])
	return "%s：%s" % [String(def.get("title", active_id)), "  ".join(parts)]
