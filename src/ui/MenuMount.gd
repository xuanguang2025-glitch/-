class_name MenuMount
extends RefCounted
## Builds and wires the main menu, and implements the one entry that changes state.
##
## Extracted from GameRoot because the 900-line ceiling is the stated reason this project keeps
## its scene script thin, and a menu is not scene logic. It is also the more honest home for
## `new_game`: that entry exists precisely because it touches four systems at once — the player
## layer, the save file, the clock and weather, and the spawn transform — and a function that
## coordinates four subsystems belongs to none of them. Everything it needs is a parameter, so
## there is no hidden handle back to the scene.


static func mount(host: Node, creation, streamer, player, spawn: Vector2) -> MainMenu:
	if host.menu != null:
		return host.menu
	var menu := MainMenu.new()
	menu.name = "MainMenu"
	menu.bind(MainMenu.RESUME, func() -> void: print("[menu] 继续"))
	menu.bind(MainMenu.NEW_GAME, func() -> void: new_game(creation, player, spawn))
	menu.bind_quality(func() -> void: streamer.set_origin(streamer.origin_of_interest))
	menu.entry_chosen.connect(func(i: int) -> void:
		GameGlobals.hud_message.emit(["继续", "新游戏", "退出"][i], 2.0))
	host.add_child(menu)
	host.menu = menu
	return menu


static func new_game(creation, player, spawn: Vector2) -> void:
	creation.clear_all()
	# save_edits mirrors to the backend itself, so an extra mirror_save here would push the same
	# payload twice and make the next boot's restore count ambiguous.
	creation.save_edits()
	GameGlobals.set_time(8.0)
	GameGlobals.set_weather(int(GameGlobals.Weather.CLEAR), 0.0)
	if player != null:
		player.position = Vector3(spawn.x, 1.2, spawn.y)
	print("[menu] 新游戏：玩家层已清空并写入存档，对象数=%d" % creation.objects.size())
