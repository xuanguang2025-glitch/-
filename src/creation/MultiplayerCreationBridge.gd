class_name MultiplayerCreationBridge
extends RefCounted
## Phase 187: the seam between the multiplayer client and the creation system.
##
## When a server confirms a creation or streams one from another player, this bridge writes it
## into CreationSystem through the same _put path a local click uses. Keeping that logic here
## rather than inside CreationSystem keeps the editor file under the R4 ceiling and makes the
## multiplayer-on/off boundary explicit: remove this bridge and the editor is single-player
## again with nothing to untangle.

var _creation: CreationSystem


func bind(creation: CreationSystem) -> void:
	_creation = creation
	var mp: MultiplayerClient = creation.get_tree().get_first_node_in_group("multiplayer")
	if mp == null:
		return
	mp.remote_creation.connect(func(obj: Dictionary):
		if bool(obj.get("removed", false)):
			apply_remote_removal(obj)
		else:
			apply_remote_creation(obj))
	mp.creation_confirmed.connect(func(req_id: String, obj_id: int):
		GameGlobals.say("服务器确认放置 #%d" % obj_id))
	mp.creation_rejected.connect(func(req_id: String, reason: String):
		GameGlobals.say("服务器拒绝放置：%s" % reason))


func apply_remote_creation(obj: Dictionary) -> void:
	if _creation == null:
		return
	var st := CreationSystem._normalize(obj)
	if not _creation.objects.has(int(st["id"])):
		_creation._put(st)
		_creation._undo.append({"op": "add", "obj": st.duplicate()})
		_creation._redo.clear()
		_creation.changed.emit()
	else:
		_creation.objects[int(st["id"])] = st
		_creation._realize(_creation.objects[int(st["id"])])


func apply_remote_removal(obj: Dictionary) -> void:
	if _creation == null:
		return
	var id := int(obj.get("id", 0))
	if _creation.objects.has(id):
		_creation._destroy(id)
		_creation.changed.emit()


## In multiplayer mode, request a creation from the server instead of placing locally. Returns
## -1 (pending) so the caller knows the object has not yet entered the world.
func request_place(mp: MultiplayerClient, tpl: Dictionary, c: Vector2, yaw_v: float,
		scale_v: float) -> int:
	mp.request_create(String(tpl["id"]), c.x, c.y, yaw_v, scale_v,
		String(tpl.get("name", "")), int(tpl.get("occ", -1)))
	GameGlobals.say("已向服务器请求放置…")
	return -1
