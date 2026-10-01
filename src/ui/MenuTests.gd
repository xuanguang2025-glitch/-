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
