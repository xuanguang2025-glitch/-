class_name BusinessRegistry
extends RefCounted
## Phase 136 / 168: the bridge from "a player placed a shopfront" to "this district has one
## more retail business, and therefore more jobs".
##
## Registration is per-object and symmetric — storing registers, destroying or replacing
## unregisters — so undo, redo, dragging a shop across a district line and reloading a save all
## land on the same ledger without a recount. Recounting the object table on every store would
## turn the 1000-object stress pass quadratic for no gain in correctness.
##
## The catalogue entries that count are the ones with a shopfront a customer can walk into. An
## office tower employs people but sells nothing, so it is deliberately not here.

const BUSINESS := {"mall": true, "shopfront": true}

var _by_district: Dictionary = {}	# district name -> {n: int, at: Vector2}
var _district_of: Dictionary = {}	# object id -> district name it registered in


func count_of(tpl_id: String) -> bool:
	return BUSINESS.has(tpl_id)


## Registers `st` if it is a business, after releasing whatever that id held before. Returns
## nothing the caller needs: the ledger is the observable output, asserted by --create-test.
func store(st: Dictionary, sim: CitySim) -> void:
	var id := int(st["id"])
	destroy(id, sim)
	if sim == null or not BUSINESS.has(String(st["tpl"])):
		return
	var p := Vector2(float(st["x"]), float(st["z"]))
	var dn := sim.district_at(p)
	if not sim.districts.has(dn):
		# A shop outside the simulated districts changes the map but not the ledger; saying so
		# is the point of the check, otherwise the player would assume it registered.
		GameGlobals.say("%s 不在城市经济模拟的街区内，未计入账本" % dn)
		return
	_district_of[id] = dn
	var e: Dictionary = _by_district.get(dn, {"n": 0, "at": p})
	e["n"] = int(e["n"]) + 1
	_by_district[dn] = e
	if bool(sim.apply_player_action("open_shop", p)["ok"]):
		GameGlobals.say("商铺已计入 %s 街区经济：就业 %d" % [dn, sim.total_employment()])


func destroy(id: int, sim: CitySim) -> void:
	if not _district_of.has(id):
		return
	var dn := String(_district_of[id])
	_district_of.erase(id)
	var e: Dictionary = _by_district.get(dn, {})
	if e.is_empty():
		return
	e["n"] = maxi(0, int(e["n"]) - 1)
	if sim == null:
		return
	if bool(sim.apply_player_action("close_shop", Vector2(e["at"]))["ok"]):
		GameGlobals.say("商铺已撤出 %s 街区经济：就业 %d" % [dn, sim.total_employment()])


## Everything was thrown away, so every registration has to be released too — otherwise a
## cleared city keeps employing staff for shops that no longer exist.
func clear(sim: CitySim) -> void:
	for id in _district_of.keys():
		destroy(int(id), sim)
	_by_district.clear()
	_district_of.clear()


func registered() -> int:
	return _district_of.size()
