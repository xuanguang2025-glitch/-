class_name TriangleBudget
extends RefCounted
## Phase 153: what player content costs, tracked per object.
##
## Existing objects contribute the triangle count measured when they were built, because a
## road's cost is its length and a scaled tower's is not its catalogue entry. A candidate
## contributes what its generator actually emits. Nothing here is an estimate of the renderer's
## cost — the numbers come from building the thing.
##
## The total is maintained incrementally. Recounting the object table on every placement would
## make each click cost what all previous clicks cost, which turns the 1000-object stress pass
## quadratic for no gain in correctness; `recount` exists so a test can prove the two agree.

var _total := 0
var _of: Dictionary = {}


func add(id: int, tris: int) -> void:
	_total += tris - int(_of.get(id, 0))
	_of[id] = tris


func remove(id: int) -> void:
	_total -= int(_of.get(id, 0))
	_of.erase(id)


func clear() -> void:
	_total = 0
	_of.clear()


func total() -> int:
	return _total


func projected(tpl_id: String) -> int:
	return _total + BuildTemplates.tri_cost(tpl_id)


func recount(objects: Dictionary) -> int:
	var t := 0
	for id in objects.keys():
		t += int((objects[id] as Dictionary).get("tris", 0))
	return t
