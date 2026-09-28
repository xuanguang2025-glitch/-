class_name Validation
extends RefCounted
## "May anything be built here?" - the single gate every generator must pass through.
##
## Both the player's editor and any future AI city generator ask this same question, so a
## generated district cannot bypass the rules a hand-placed building obeys. The reason comes
## back as an enum rather than a bool because the editor has to say *why* a spot is refused,
## and because a rejected placement is only debuggable if it is attributed.

enum Reason { OK, OFF_MAP, WATER, BANK, PARK, MAJOR_ROAD, LOCAL_STREET, GENERATED_BUILDING, OVERLAP }

const NAMES := {
	Reason.OK: "可建造",
	Reason.OFF_MAP: "超出市界",
	Reason.WATER: "黄浦江 / 苏州河",
	Reason.BANK: "河岸滩地",
	Reason.PARK: "公园绿地",
	Reason.MAJOR_ROAD: "城市干道",
	Reason.LOCAL_STREET: "街区道路",
	Reason.GENERATED_BUILDING: "已有建筑",
	Reason.OVERLAP: "与你的作品重叠",
}

## How far a footprint must sit from each hazard. Water and banks are generous because the
## terrain drops away there and a tower would float.
const MARGIN_WATER := 6.0
const MARGIN_BANK := 16.0
const MARGIN_ROAD := 2.0


static func label(r: int) -> String:
	return NAMES.get(r, "?")


## near: Array of Vector2 already-placed centres; radius: their combined clearance.
static func check(c: Vector2, half: float, near: Array, streamer: WorldStreamer) -> int:
	if absf(c.x) > GameGlobals.WORLD_HALF - half or absf(c.y) > GameGlobals.WORLD_HALF - half:
		return Reason.OFF_MAP
	var d: float = CityData.water_dist_q(c)
	if d < MARGIN_WATER:
		return Reason.WATER
	if d < MARGIN_BANK:
		return Reason.BANK
	if CityData.in_park(c):
		return Reason.PARK
	if CityData.major_gap(c) < half * 0.5 + MARGIN_ROAD:
		return Reason.MAJOR_ROAD
	if streamer != null and streamer.is_occupied(c):
		return Reason.GENERATED_BUILDING
	for p in near:
		if c.distance_to(p) < half * 1.35:
			return Reason.OVERLAP
	return Reason.OK
