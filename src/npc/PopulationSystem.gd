class_name PopulationSystem
extends Node
## Turns the generated city into a population census, and back again.
##
## Every home, job, shop and park is derived from the block archetype the generator
## actually placed — so if the CBD is dense with towers, that is where the office jobs
## are, and the commute lengths fall out of the geography instead of being hand-placed.
##
## This is also the AI tier-2 layer: the district totals are a statistical population that
## does not need any individual agent to exist.

var homes: Array = []
var jobs: Dictionary = {}
var retail: Array = []
var parks: Array = []
var landmarks: Array = []
var district_pop: Dictionary = {}
var total_pop: int = 0
var scan_ms: int = 0
var _rng := RandomNumberGenerator.new()

## Residents per block, by archetype. Roughly: a 小区 of six 18-storey point slabs really is
## about 1500 people, a lilong lane about a hundred.
const HOME_CAP := {
	"XIAOQU": 1150, "DENSE_WALKUP": 620, "LILONG": 130, "VILLAS": 26,
}
## Office jobs per tower block, only where the district actually reads as a business area.
const OFFICE_CAP := 1400
const RETAIL_CAP := 480
const INDUSTRY_CAP := 360

const OFFICE_STYLES := ["cbd_tower", "modern_mix", "diplomatic", "sprawl_tower"]


func _ready() -> void:
	add_to_group("population")
	_rng.seed = 0xB0A5
	var t0 := Time.get_ticks_msec()
	_scan()
	scan_ms = Time.get_ticks_msec() - t0
	print("[pop] homes=%d retail=%d parks=%d total_pop=%d scan=%dms" % [
		homes.size(), retail.size(), parks.size(), total_pop, scan_ms])


func _scan() -> void:
	homes.clear()
	jobs.clear()
	retail.clear()
	parks.clear()
	district_pop.clear()
	total_pop = 0
	for pool in ["office", "retail", "industry", "school", "hospital", "civic"]:
		jobs[pool] = []
	var ni := int(GameGlobals.WORLD_HALF / Lattice.BASE_U) + 1
	var nj := int(GameGlobals.WORLD_HALF / Lattice.BASE_V) + 1
	for i in range(-ni, ni + 1):
		for j in range(-nj, nj + 1):
			var c := Lattice.cell_center(i, j)
			if CityData.blocks_building(c, -6.0):
				continue
			var kind := Lattice.cell_kind(i, j)
			var dist := CityData.district_q(c)
			var style := String(dist["style"])
			var dn := String(dist["name"])
			match kind:
				"XIAOQU", "DENSE_WALKUP", "LILONG", "VILLAS":
					var cap := int(HOME_CAP.get(kind, 200))
					homes.append({"p": c, "cap": cap, "d": dn})
					total_pop += cap
					district_pop[dn] = int(district_pop.get(dn, 0)) + cap
				"SPLIT_TOWER", "OFFICE_PLINTH":
					if style in OFFICE_STYLES:
						jobs["office"].append({"p": c, "d": dn})
						_employ(dn, OFFICE_CAP)
					else:
						homes.append({"p": c, "cap": 520, "d": dn})
						total_pop += 520
						district_pop[dn] = int(district_pop.get(dn, 0)) + 520
				"MALL", "SHOPFRONT_ROW":
					retail.append({"p": c, "d": dn})
					jobs["retail"].append({"p": c, "d": dn})
					_employ(dn, RETAIL_CAP)
				"FACTORY":
					jobs["industry"].append({"p": c, "d": dn})
					_employ(dn, INDUSTRY_CAP)
				"PARK_CELL":
					parks.append({"p": c})
	# Landmarks give the city its civic, medical and educational anchors.
	for lm in CityData.LANDMARKS:
		var lp := Vector2(lm["x"], lm["z"])
		landmarks.append(lp)
		match String(lm["type"]):
			"museum", "grand_theatre", "jingan_temple", "cathedral", "stadium", \
			"railway_station", "hongqiao_hub", "pudong_airport", "municipal_hall":
				jobs["civic"].append({"p": lp, "d": String(CityData.district_q(lp)["name"])})
			"yuyuan", "xintiandi", "plaza", "wujiaochang", "pearl_tower", "bund_row":
				retail.append({"p": lp, "d": String(CityData.district_q(lp)["name"])})
	for pk in CityData.PARKS:
		parks.append({"p": Vector2(pk["x"], pk["z"])})
	# Schools and hospitals are towers that are not offices: take a slice of the office
	# stock so students and medical staff have somewhere plausible to go.
	var off: Array = jobs["office"]
	for k in mini(28, off.size() / 3):
		var src: Dictionary = off[k * 3]
		jobs["school"].append({"p": src["p"] + Vector2(38.0, -26.0), "d": src["d"]})
	for k in mini(20, off.size() / 4):
		var src2: Dictionary = off[k * 4]
		jobs["hospital"].append({"p": src2["p"] + Vector2(-30.0, 44.0), "d": src2["d"]})


## Jobs create daytime population in the district they sit in, at less than face value
## because a share of commuters live elsewhere.
func _employ(dn: String, cap: int) -> void:
	district_pop[dn] = int(district_pop.get(dn, 0)) + int(cap * 0.35)


func district_total(name: String) -> int:
	return int(district_pop.get(name, 0))


# --- Goal resolution --------------------------------------------------------
func pick_home(near: Vector2, _rnd: RandomNumberGenerator) -> Vector2:
	return _pick_anchored(homes, near, _rng, 26)


## Jobs cluster around where people already live, with a long tail — the real commute
## distribution, not a uniform random pick across the whole map.
func pick_job(zone: String, from_home: Vector2, _rnd: RandomNumberGenerator) -> Vector2:
	var pool: Array = jobs.get(zone, [])
	if pool.is_empty():
		for k in jobs.keys():
			if not (jobs[k] as Array).is_empty():
				pool = jobs[k]
				break
	if pool.is_empty():
		return from_home
	return _pick_anchored(pool, from_home, _rng, 22)


func resolve(kind: String, hint: Vector2) -> Vector2:
	match kind:
		"home":
			return hint
		"work":
			return hint
		"retail":
			return _pick_anchored(retail, hint, _rng, 14)
		"park":
			return _pick_anchored(parks, hint, _rng, 10)
		"landmark":
			return _pick_anchored(landmarks, hint, _rng, 8)
		_:
			return _pick_anchored(homes, hint, _rng, 10)


## Sample a handful of candidates and take one of the closest, so a person's errand is
## genuinely near them instead of on the far side of the city.
func _pick_anchored(pool: Array, anchor: Vector2, _rnd: RandomNumberGenerator,
		sample: int) -> Vector2:
	if pool.is_empty():
		return anchor
	var best: Array = []
	for k in sample:
		var e: Variant = pool[_rng.randi_range(0, pool.size() - 1)]
		var p: Vector2 = e["p"] if e is Dictionary else e
		best.append({"p": p, "d": p.distance_squared_to(anchor)})
	best.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var take := mini(3, best.size())
	return best[_rng.randi_range(0, take - 1)]["p"]


## How many people should be out and about right now, by hour. Used to size the crowd.
func active_share(hour: float) -> float:
	if hour < 5.5 or hour > 23.0:
		return 0.03
	if hour < 7.0:
		return 0.12
	if hour < 9.5:
		return 0.95
	if hour < 11.5:
		return 0.55
	if hour < 13.5:
		return 0.92
	if hour < 17.0:
		return 0.55
	if hour < 19.5:
		return 1.0
	if hour < 22.0:
		return 0.72
	return 0.28
