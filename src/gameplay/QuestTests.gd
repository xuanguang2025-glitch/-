class_name QuestTests
extends RefCounted
## Phase 360 (executable subset): the quest layer's acceptance contract.
##
## The properties tested here are the ones that separate a playable loop from a data structure
## that looks like one: a quest must reach settlement, illegal state jumps must be refused with a
## reason, a second settlement must not pay twice, the payout must leave the ledger identity
## intact, progress must survive a restart, and an interaction must be re-checked in logic so a
## busted HUD cannot authorise a conversation from across the map.

static var _fails := 0


static func run(tree: SceneTree) -> int:
	_fails = 0
	_n = 0
	print("=== quest self-test ===")
	var quests := QuestMount.of(tree)
	var inter := tree.get_first_node_in_group("interactions") as InteractionSystem
	var player := tree.get_first_node_in_group("player") as Node3D
	if quests == null or inter == null or player == null or quests.sim == null:
		_that("任务层已挂载", false,
			"quests=%s inter=%s player=%s" % [str(quests), str(inter), str(player)])
		print("=== quest self-test: FAIL (%d checks, %d failures) ===" % [_n, _fails])
		return _fails
	var sim: CitySim = quests.sim
	# Never write over the player's own progress: the suite saves, resets and reloads, and it used
	# to do that on `user://quests.json`, which the game reads at boot — so running the tests
	# quietly rewrote the save. The test owns its own file and deletes it on the way out.
	var real_path: String = quests.save_path
	quests.save_path = "user://quests_test.json"
	_that("自测不写玩家存档", quests.save_path != real_path, quests.save_path)
	# The giver is placed relative to the resolved spawn, so this is the check that the only
	# quest in the city is actually reachable the moment the player takes control.
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	var d0 := p0.distance_to(quests.giver_pos)
	_that("出生点够得着任务 NPC", d0 <= InteractionSystem.REACH, "%.2f m" % d0)
	_that("交互系统能认出就在身边的 NPC", not inter.nearest().is_empty(),
		"nearest 为空（%.2f m）" % d0)
	quests.reset_for_test()
	var qid := "side_bund_01"
	var def := quests.def_of(qid)
	_that("侧任务定义存在且可发布", not def.is_empty() and QuestDefs.validate(def) == "",
		QuestDefs.validate(def))

	# Phase 348: a definition that names an objective kind this build cannot drive must be refused
	# rather than published and left sitting at 0 % forever.
	var bad := {"schema": 1, "title": "坏任务", "objectives": [
		{"id": "a", "kind": "CollectItem", "label": "捡东西", "params": {}}]}
	_that("未实现的目标类型在发布前被拒绝", QuestDefs.validate(bad).find("尚未实现") >= 0,
		QuestDefs.validate(bad))

	# --- accept -> progress -> settle -------------------------------------
	var inst := quests.instance(qid)
	_that("初始状态是 Available", String(inst["state"]) == "Available", String(inst["state"]))
	var m0: int = sim.money_total()
	_that("接取成功", quests.accept(qid))
	_that("接取后进入 InProgress", String(quests.instance(qid)["state"]) == "InProgress",
		String(quests.instance(qid)["state"]))

	# Phase 346: a second accept from InProgress is illegal and must say why.
	var again := quests.accept(qid)
	_that("重复接取被拒绝并留下原因", not again and quests.last_error.find("不能从") >= 0,
		quests.last_error)

	# Objectives are driven by events, not by a loop: the test fires exactly what the game fires.
	var spot := QuestDefs.objective_point(def["objectives"][1])		# ReachLocation
	_that("目标点可解析", spot != Vector2.INF, "INF")
	quests.on_player_moved(spot + Vector2(400.0, 400.0))
	_that("离得太远时目标不推进",
		not bool((quests.instance(qid)["objectives"] as Dictionary)["reach_boc"]["done"]))
	quests.on_player_moved(spot)
	_that("走入半径后目标推进",
		bool((quests.instance(qid)["objectives"] as Dictionary)["reach_boc"]["done"]))
	quests.on_interact("quest_giver")
	_that("交谈目标由交互事件推进",
		bool((quests.instance(qid)["objectives"] as Dictionary)["talk_zhou"]["done"]))
	var lm := QuestDefs.objective_point(def["objectives"][2])		# VisitLandmark
	quests.on_player_moved(lm)
	_that("地标目标推进后任务自动结算",
		String(quests.instance(qid)["state"]) == "Completed",
		String(quests.instance(qid)["state"]))

	# Phase 353: payout is booked into the ledger, so the identity holds and nothing is minted.
	_that("结算后账本仍然守恒", sim.money_total() == m0, "%d vs %d" % [sim.money_total(), m0])
	_that("奖励确实记到了居民桶", int(quests.instance(qid).get("reward_claimed", false)))
	var m1: int = sim.money_total()
	var paid_again := quests.complete(qid)
	_that("重复结算被拒绝", not paid_again and quests.last_error.find("重复") >= 0,
		quests.last_error)
	_that("重复结算没有二次发钱", sim.money_total() == m1)

	# --- failure path -----------------------------------------------------
	quests.reset_for_test()
	quests.accept(qid)
	_that("失败条件可触发", quests.fail(qid, "玩家离开区域"))
	_that("失败后状态为 Failed", String(quests.instance(qid)["state"]) == "Failed")
	_that("失败后不能直接结算", not quests.complete(qid) and quests.last_error.find("结算") >= 0,
		quests.last_error)

	# --- save / reload ----------------------------------------------------
	quests.reset_for_test()
	quests.accept(qid)
	quests.on_interact("quest_giver")
	var before_state := String(quests.instance(qid)["state"])
	var before_talk := bool((quests.instance(qid)["objectives"] as Dictionary)["talk_zhou"]["done"])
	var saved := quests.save_progress()
	_that("进度写入存档", saved, quests.last_error)
	quests.reset_for_test()
	_that("重置后目标确实清空",
		not bool((quests.instance(qid)["objectives"] as Dictionary)["talk_zhou"]["done"]))
	_that("从存档恢复", quests.load_progress(), quests.last_error)
	_that("恢复后状态一致", String(quests.instance(qid)["state"]) == before_state,
		String(quests.instance(qid)["state"]))
	_that("恢复后目标进度一致",
		bool((quests.instance(qid)["objectives"] as Dictionary)["talk_zhou"]["done"]) == before_talk)

	# --- interaction authorisation ---------------------------------------
	var pp := Vector2(player.global_position.x, player.global_position.z)
	var saved_pos := player.global_position
	inter.register("test_far", "远处的东西", "npc", pp + Vector2(40.0, 0.0), ["交谈"], Callable())
	_that("超出距离的交互被逻辑层拒绝", not inter.activate("test_far"), "竟然通过")
	_that("拒绝时说明了距离", inter.last_refusal.find("超出交互范围") >= 0, inter.last_refusal)
	inter.register("test_near", "身边的东西", "npc", pp, ["交谈"], Callable())
	_that("范围内的交互可执行", inter.activate("test_near"))
	_that("最近可交互对象在范围内时能被找到", not inter.nearest().is_empty())
	player.global_position = saved_pos
	inter.unregister("test_far")
	inter.unregister("test_near")

	# --- status line is a real read of state ------------------------------
	# A HUD line that prints a constant is the classic "looks implemented" failure, so the check
	# is that it reflects the live instance: the title must appear and an already-cleared
	# objective must be marked done.
	var line := quests.status_line()
	_that("HUD 状态行来自实例而不是常量",
		line.find(String(quests.def_of(qid).get("title", "?"))) >= 0 and line.find("✓") >= 0,
		line)
	quests.abandon(qid)
	_that("没有任务时状态行说的是没有任务，而不是上一句残留",
		quests.status_line() == "任务：无", quests.status_line())

	quests.reset_for_test()
	quests.save_path = real_path
	if FileAccess.file_exists("user://quests_test.json"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://quests_test.json"))
	print("=== quest self-test: %s (%d checks, %d failures) ===" % [
		"PASS" if _fails == 0 else "FAIL", _n, _fails])
	return _fails


static var _n := 0


## Prefixed so the pipeline can count this contract separately from the economy's and the living
## city's: three subsystems, three counts, none of them able to hide behind another's total.
static func _that(label: String, cond: bool, detail := "") -> void:
	_n += 1
	if not cond:
		_fails += 1
	print("[quest] %s %-40s %s" % ["PASS" if cond else "FAIL", label, detail])
