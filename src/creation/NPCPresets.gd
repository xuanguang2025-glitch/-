class_name NPCPresets
extends RefCounted
## Phase 137: who the player can create.
##
## A palette of identities rather than a free-text form, because the editor's input surface is
## a game HUD and a name field nobody can type into is a mock-up. Each entry carries a real
## occupation from `OccupationTable`, so a created person follows the same shift, commute,
## leisure and consumption schedule as a generated one — which is the whole point of creating
## them. Ids are distinct because the placed record stores its template id, and a reload has to
## be able to tell a shopkeeper from a doctor.

const LIST := [
	{"id": "npc_shopkeeper", "kind": "npc", "name": "陈美玲", "role": "店主",
		"occ": OccupationTable.Occ.SHOPKEEPER, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "historic_mix"},
	{"id": "npc_office", "kind": "npc", "name": "周立群", "role": "白领",
		"occ": OccupationTable.Occ.OFFICE, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "cbd_tower"},
	{"id": "npc_engineer", "kind": "npc", "name": "吴敏", "role": "工程师",
		"occ": OccupationTable.Occ.ENGINEER, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "modern_mix"},
	{"id": "npc_teacher", "kind": "npc", "name": "何静怡", "role": "教师",
		"occ": OccupationTable.Occ.TEACHER, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "diplomatic"},
	{"id": "npc_doctor", "kind": "npc", "name": "戴文彬", "role": "医护",
		"occ": OccupationTable.Occ.DOCTOR, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "modern_mix"},
	{"id": "npc_driver", "kind": "npc", "name": "赵德海", "role": "司机",
		"occ": OccupationTable.Occ.DRIVER, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "old_industrial"},
	{"id": "npc_worker", "kind": "npc", "name": "孙巧凤", "role": "工人",
		"occ": OccupationTable.Occ.WORKER, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "port_industry"},
	{"id": "npc_police", "kind": "npc", "name": "李国栋", "role": "民警",
		"occ": OccupationTable.Occ.POLICE, "size": Vector2(1.2, 1.2),
		"height": 0.0, "style": "civic"},
]


static func count() -> int:
	return LIST.size()


static func get_at(i: int) -> Dictionary:
	return LIST[clampi(i, 0, LIST.size() - 1)]


static func find(id: String) -> Dictionary:
	for t in LIST:
		if String(t["id"]) == id:
			return t
	return LIST[0]
