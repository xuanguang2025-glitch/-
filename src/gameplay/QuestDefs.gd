class_name QuestDefs
extends RefCounted
## Phase 346 / 348: quest *definitions*, separated from instances on purpose.
##
## The spec lists fifteen objective kinds. Only three of them are backed by a real listener in
## this build, and the difference is written down rather than papered over: `KINDS` is the
## vocabulary, `IMPLEMENTED` is what can actually be activated, and `validate()` refuses a
## definition that asks for anything else. A quest that cannot progress is worse than a quest that
## does not exist, because the player has already accepted it.
##
## Definitions are plain dictionaries rather than custom Resources so that the save file, the
## tests and (later) the creator editor all speak the same shape with no serialiser in between.

const SCHEMA_VERSION := 1

## The vocabulary from Phase 347, verbatim and complete. Presence here is NOT a claim of support.
const KINDS := [
	"ReachLocation", "TalkToNPC", "CollectItem", "DeliverItem", "PurchaseItem", "DriveVehicle",
	"VisitLandmark", "DiscoverArea", "CompleteRace", "EarnMoney", "BuildStructure",
	"OperateBusiness", "HelpNPC", "CompleteQuest", "ParticipateInEvent",
]

## What this build can actually drive from an event today.
const IMPLEMENTED := ["ReachLocation", "TalkToNPC", "VisitLandmark"]

const DEFS := {
	"side_bund_01": {
		"schema": SCHEMA_VERSION,
		"title": "外滩三件事",
		"desc": "老周在路口摆了张折叠桌。他说这条街最近冷清，让年轻人替他走一趟——"
			+ "先去中国银行大楼底下看看，再去海关大楼门口听一次钟。",
		"type": "side",
		"prerequisites": [],
		"objectives": [
			{
				"id": "talk_zhou",
				"kind": "TalkToNPC",
				"label": "和老周说一声",
				"params": {"npc": "quest_giver"},
			},
			{
				"id": "reach_boc",
				"kind": "ReachLocation",
				"label": "走到中国银行大楼楼下",
				"params": {"x": 1304.0, "z": 220.0, "radius": 26.0},
			},
			{
				"id": "visit_customs",
				"kind": "VisitLandmark",
				"label": "到海关大楼门口",
				"params": {"landmark": "海关大楼", "radius": 34.0},
			},
		],
		"completion": "all",
		"failure": [],
		## Paid out of the ledger's resident bucket, so the four-bucket identity still holds.
		"reward": {"cents": 240, "bucket": "resident"},
		"world_effects": [],
		"multiplayer": "solo",
	},
}


static func get_def(id: String) -> Dictionary:
	return DEFS.get(id, {})


static func ids() -> Array:
	return DEFS.keys()


## Returns "" when the definition is publishable, otherwise the reason it is not. A validator that
## only returns a bool leaves the creator (or the next agent) guessing which rule fired.
static func validate(def: Dictionary) -> String:
	if def.is_empty():
		return "定义不存在"
	if int(def.get("schema", 0)) != SCHEMA_VERSION:
		return "schema 版本不匹配：%s" % str(def.get("schema", "缺失"))
	if String(def.get("title", "")).is_empty():
		return "缺少标题"
	var objs: Array = def.get("objectives", [])
	if objs.is_empty():
		return "任务没有任何目标"
	var seen := {}
	for o in objs:
		var d: Dictionary = o
		var id := String(d.get("id", ""))
		if id.is_empty():
			return "存在没有 id 的目标"
		if seen.has(id):
			return "目标 id 重复：%s" % id
		seen[id] = true
		var kind := String(d.get("kind", ""))
		if not KINDS.has(kind):
			return "未知目标类型：%s" % kind
		if not IMPLEMENTED.has(kind):
			return "目标类型尚未实现：%s（已实现：%s）" % [kind, ", ".join(IMPLEMENTED)]
		if String(d.get("label", "")).is_empty():
			return "目标 %s 没有可显示文字" % id
		var p: Dictionary = d.get("params", {})
		match kind:
			"ReachLocation":
				if not (p.has("x") and p.has("z") and p.has("radius")):
					return "目标 %s 缺少 x/z/radius" % id
				if float(p.get("radius", 0.0)) <= 0.0:
					return "目标 %s 的 radius 必须为正" % id
			"VisitLandmark":
				if String(p.get("landmark", "")).is_empty():
					return "目标 %s 缺少 landmark" % id
				if _landmark_pos(String(p["landmark"])) == Vector2.INF:
					return "目标 %s 指向不存在的地标：%s" % [id, String(p["landmark"])]
			"TalkToNPC":
				if String(p.get("npc", "")).is_empty():
					return "目标 %s 缺少 npc" % id
	var reward: Dictionary = def.get("reward", {})
	if int(reward.get("cents", 0)) < 0:
		return "奖励金额不能为负"
	# Phase 348's "永远无法满足的条件": a TalkToNPC objective whose NPC is not the giver and is
	# not registered anywhere would sit at 0 % forever.
	return ""


static func _landmark_pos(name: String) -> Vector2:
	for lm in CityData.LANDMARKS:
		if String(lm["name"]) == name:
			return Vector2(float(lm["x"]), float(lm["z"]))
	return Vector2.INF


## The position an objective cares about, or INF when it is not a place objective.
static func objective_point(o: Dictionary) -> Vector2:
	var kind := String(o.get("kind", ""))
	var p: Dictionary = o.get("params", {})
	match kind:
		"ReachLocation":
			return Vector2(float(p.get("x", 0.0)), float(p.get("z", 0.0)))
		"VisitLandmark":
			return _landmark_pos(String(p.get("landmark", "")))
		_:
			return Vector2.INF
