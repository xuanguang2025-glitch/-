class_name MenuTests
extends RefCounted
## Phase 122 / 123 acceptance for the main menu, driven headlessly through the same entry points
## the mouse uses (`choose`, `set_quality`) — because a menu that only a click can open is a menu
## no gate has ever verified, and the failure mode people actually hit is a button that exists and
## does nothing.
##
## The last two checks are the ones that matter most here: the panel must not pause the tree, and
## the city must keep streaming behind it. Both are properties of how the menu is mounted, not of
## how it looks, and neither is visible in a screenshot.


static func run(root) -> int:
	var fails := 0
	var n := 0
	print("=== main menu self-test ===")
	var menu: MainMenu = root.mount_menu(true)
	fails += _that("菜单可被挂载", menu != null)
	n += 1
	fails += _that("挂载后默认是打开的", menu != null and menu.is_open(), "is_open=false")
	n += 1

	# 新游戏 must actually empty the player layer, and the emptied state must reach the save file —
	# otherwise the next 继续 restores the city the player just asked to erase.
	var spots := ValidationTests.find_spots(2, 30.0, root.streamer)
	for s in spots:
		root.creation.place(s)
	var placed: int = int(root.creation.objects.size())
	fails += _that("测试前置：确实放进了作品", placed > 0, "objects=%d" % placed)
	n += 1
	root.creation.save_edits()
	menu.choose(MainMenu.NEW_GAME)
	fails += _that("新游戏清空了玩家层", root.creation.objects.is_empty(),
		"残留 %d 件" % root.creation.objects.size())
	n += 1
	fails += _that("清空后的城市层写进了存档", _save_is_empty(), "存档里仍有作品")
	n += 1

	# Quality must be a real switch, not a label: the tier drives stream radius and budgets, so
	# asserting the config changed is what proves the button is wired to the system.
	var before: Dictionary = QualityPresets.cfg()
	menu.set_quality(QualityPresets.Tier.LOW)
	var after: Dictionary = QualityPresets.cfg()
	fails += _that("画质切档真的改了配置",
		int(after["stream_radius"]) != int(before["stream_radius"]),
		"%s → %s" % [str(before["stream_radius"]), str(after["stream_radius"])])
	n += 1
	fails += _that("四档画质都在且标出当前档",
		QualityPresets.tier_count() == 4 and menu.current_quality() == QualityPresets.Tier.LOW,
		"档位=%d 当前=%d" % [QualityPresets.tier_count(), menu.current_quality()])
	n += 1

	# The panel must not stop the world. If it did, every gate that waits on chunk streaming would
	# hang, and the menu would be a loading screen pretending to be a pause.
	fails += _that("菜单不暂停场景树",
		not root.get_tree().paused and menu.process_mode == Node.PROCESS_MODE_INHERIT,
		"paused=%s process_mode=%d" % [str(root.get_tree().paused), menu.process_mode])
	n += 1
	var built0: int = int(root.streamer.stats()["built_total"])
	await root.get_tree().create_timer(2.0).timeout
	var built1: int = int(root.streamer.stats()["built_total"])
	fails += _that("菜单开着时城市仍在流式生成", built1 > built0,
		"built %d → %d" % [built0, built1])
	n += 1

	menu.choose(MainMenu.RESUME)
	fails += _that("继续关闭了菜单", not menu.is_open(), "仍然打开")
	n += 1

	# Injected through the viewport so the check walks the same route a keypress walks
	# (viewport -> gui -> unhandled) instead of calling the handler directly, which would still
	# pass after the binding was deleted. Two engine facts learned the hard way here:
	# Input.parse_input_event() is a silent no-op headless, and Viewport.push_input() called from
	# inside _process crashes the engine — so the push is deferred and one frame is awaited.
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	root.get_viewport().call_deferred("push_input", ev)
	await root.get_tree().process_frame
	fails += _that("Esc 能重新打开已关闭的菜单", menu.is_open(), "仍然关闭")
	n += 1
	menu.close_menu()

	# The off-by-one that made 退出 a dead button: the labels lived in an inline array while the
	# indices lived in constants, three buttons were built for four constants, and 退出 dispatched
	# index 2 into a binding table that only had 0 and 1. Nothing here quits, so the guard is
	# structural — the row displayed at QUIT must be the row that says 退出.
	fails += _that("退出按钮确实坐在 QUIT 索引上（曾错位一格而空转）",
		menu.button_at(MainMenu.QUIT) != null
		and menu.entry_label(MainMenu.QUIT) == "退出"
		and menu.row_count() == MainMenu.ENTRIES.size(),
		"rows=%d 退出=%s" % [menu.row_count(), menu.entry_label(MainMenu.QUIT)])
	n += 1
	fails += _that("每个入口都有可点的行", menu.button_at(MainMenu.RESUME) != null
		and menu.button_at(MainMenu.NEW_GAME) != null
		and menu.button_at(MainMenu.NET) != null, "有入口没有对应按钮")
	n += 1

	# 联机 must be a real attempt, and a failed attempt has to say why. Headless here there is no
	# --backend, so the honest outcome is failure with a reason — the bug this guards against is
	# the silent kind, where the button exists, the call returns, and nothing anywhere records
	# that the player never got online.
	var ns = root.get_tree().get_first_node_in_group("net_session")
	fails += _that("联机入口接到真的会话对象上", ns != null, "找不到 net_session")
	n += 1
	if ns != null:
		fails += _that("未连接时不谎报余额（-1 = 服务器还没说过）", int(ns.balance()) < 0,
			"balance=%d" % int(ns.balance()))
		n += 1
		var ok_join: bool = ns.join("127.0.0.1", 9876)
		fails += _that("没有后端时联机失败而不是静默成功", not ok_join, "竟然返回 true")
		n += 1
		fails += _that("失败原因被留下并可显示", not String(ns.detail).is_empty()
			and String(ns.detail).find("后端") >= 0, "detail=%s" % String(ns.detail))
		n += 1
		fails += _that("失败的会话不留下半个客户端", ns.client == null, "留下了 client 节点")
		n += 1

	print("=== main menu self-test: %s (%d checks, %d failures) ===" % [
		"PASS" if fails == 0 else "FAIL", n, fails])
	return fails


static func _save_is_empty() -> bool:
	if not FileAccess.file_exists("user://city_edits.json"):
		return true
	var f := FileAccess.open("user://city_edits.json", FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	return (parsed as Dictionary).get("objects", []).is_empty()


static func _that(label: String, cond: bool, detail := "") -> int:
	if cond:
		print("PASS  %s" % label)
		return 0
	print("FAIL  %s  %s" % [label, detail])
	return 1
