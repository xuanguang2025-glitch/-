class_name MainMenu
extends CanvasLayer
## Phase 122 / 123: the boot screen, and the reason the desktop shortcut is usable.
##
## Four entries, each of which has to be backed by a system that already exists — a menu item
## that only prints "功能开发中" is exactly the placeholder the spec forbids:
##   继续    the world is already loaded behind this layer, so resuming means hiding the overlay
##   新游戏  clears the player layer through CreationSystem.clear_all and writes the emptied save,
##           so the next 继续 genuinely has nothing to restore
##   画质    QualityPresets.set_tier, the same four tiers the streaming gates measure against
##   退出    SceneTree.quit
##
## Deliberately does NOT pause the scene tree. The streaming, crowd, traffic and simulation
## systems keep running underneath, which is what lets the automated gates keep waiting on
## `streamer.alive > 250`; a menu that paused the tree would hang every one of those gates, and
## the city you see behind the panel is the real city rather than a backdrop.
##
## `choose()` is public because the headless self-test drives the entries through it. A menu only
## reachable by mouse is a menu no gate has ever opened.

signal entry_chosen(index: int)
signal closed

const RESUME := 0
const NEW_GAME := 1
const QUIT := 3

var actions: Dictionary = {}		# entry index -> Callable
var quality_cb: Callable

var _root: PanelContainer
var _rows: Array = []
var _quality_labels: Array = []
var _open := true


func _ready() -> void:
	layer = 70
	_root = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.040, 0.050, 0.90)
	sb.set_corner_radius_all(4)
	sb.border_color = Color(0.16, 0.42, 0.85, 0.70)
	sb.set_border_width_all(1)
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	_root.add_theme_stylebox_override("panel", sb)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_root.add_child(col)

	var title := Label.new()
	title.text = "SHANGHAI: OPEN WORLD"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	col.add_child(title)

	var sub := Label.new()
	sub.text = "上海 · 开放世界"
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color(0.42, 0.62, 0.95))
	col.add_child(sub)

	col.add_child(_sep())
	for i in 3:
		var b := _button(["继续", "新游戏（清空我的城市层）", "退出"][i])
		b.pressed.connect(func() -> void: choose(i))
		col.add_child(b)
		_rows.append(b)

	col.add_child(_sep())
	var qtitle := Label.new()
	qtitle.text = "画质"
	qtitle.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	col.add_child(qtitle)
	for t in QualityPresets.tier_count():
		var qb := _button(QualityPresets.tier_name(t))
		qb.pressed.connect(func() -> void: set_quality(t))
		col.add_child(qb)
		_quality_labels.append(qb)

	add_child(_root)
	_layout()
	_refresh()


func bind(index: int, cb: Callable) -> void:
	actions[index] = cb


func bind_quality(cb: Callable) -> void:
	quality_cb = cb


func is_open() -> bool:
	return _open


func current_quality() -> int:
	return QualityPresets.tier


func set_quality(t: int) -> void:
	QualityPresets.set_tier(t)
	if quality_cb.is_valid():
		quality_cb.call()
	_refresh()


func choose(index: int) -> void:
	entry_chosen.emit(index)
	if index == QUIT:
		get_tree().quit()
		return
	if not actions.has(index):
		return
	actions[index].call()
	if index == RESUME:
		close_menu()


func close_menu() -> void:
	_open = false
	visible = false
	closed.emit()


func open_menu() -> void:
	_open = true
	visible = true


## A menu you can close but never reopen is a boot screen, not a menu. Esc is the convention and
## costs nothing here because the tree is never paused: reopening shows the live city again.
func _unhandled_key_input(event: InputEvent) -> void:
	if not _open and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		open_menu()
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	for t in _quality_labels.size():
		var lbl: Button = _quality_labels[t]
		lbl.text = ("%s  ●" % QualityPresets.tier_name(t)) if t == QualityPresets.tier \
			else QualityPresets.tier_name(t)


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(260, 0)
	return b


func _sep() -> Control:
	var c := ColorRect.new()
	c.color = Color(0.16, 0.42, 0.85, 0.28)
	c.custom_minimum_size = Vector2(0, 1)
	return c


func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	_root.position = Vector2(vp.x * 0.5 - 160.0, vp.y * 0.5 - 190.0)
