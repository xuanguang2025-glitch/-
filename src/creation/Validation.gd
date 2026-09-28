class_name Validation
extends RefCounted
## "May anything be built here?" - the single gate every generator must pass through.
##
## Both the player's editor and any future AI city generator ask this same question, so a
## generated district cannot bypass the rules a hand-placed building obeys. The reason comes
## back as an enum rather than a bool because the editor has to say *why* a spot is refused,
## and because a rejected placement is only debuggable if it is attributed.

enum Reason {
	OK, OFF_MAP, WATER, BANK, PARK, MAJOR_ROAD, LOCAL_STREET, GENERATED_BUILDING,
	OVERLAP, ZONE_SIZE, OVER_BUDGET,
}

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
	Reason.ZONE_SIZE: "分区限制：此处只允许小体量创作",
	Reason.OVER_BUDGET: "创作预算已满（三角面）",
}

## Triangle ceiling for all player content in the world at once (Phase 153). Measured, not
## chosen: `BuildTemplates.tri_cost` builds every catalogue entry once into a throwaway context
## and counts what the generators actually emit — 12 buildings total 4834 triangles (~400 each,
## because window grids are drawn by the facade shader rather than by geometry) and 9 street
## props total 472. The 1000-object stress pass therefore costs about 400 k, and this ceiling
## is ~3.7 k mixed objects: loose enough that the gate still passes by a wide margin, tight
## enough that "keep building" cannot run the world into the ground.
const MAX_TRIS := 1500000

## How far a footprint must sit from each hazard. Water and banks are generous because the
## terrain drops away there and a tower would float.
const MARGIN_WATER := 6.0
const MARGIN_BANK := 16.0
const MARGIN_ROAD := 2.0


static func label(r: int) -> String:
	return NAMES.get(r, "?")


## near: Array of Vector2 already-placed centres; radius: their combined clearance.
## tris_projected: total triangles the world would hold if this placement were accepted, or -1
## when the caller is not asking about a whole-world budget (a spot probe, a search grid).
static func check(c: Vector2, half: float, near: Array, streamer: WorldStreamer,
		tris_projected := -1) -> int:
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
	## Phase 163: the base city's core stays readable. Size is the knob because that is what
	## actually damages a skyline - a 9 m prop in the historic core is welcome, a tower is not.
	if half > CreationZones.max_half(c):
		return Reason.ZONE_SIZE
	for p in near:
		if c.distance_to(p) < half * 1.35:
			return Reason.OVERLAP
	if tris_projected >= 0 and tris_projected > MAX_TRIS:
		return Reason.OVER_BUDGET
	return Reason.OK
