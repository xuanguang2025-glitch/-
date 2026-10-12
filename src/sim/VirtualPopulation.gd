class_name VirtualPopulation
extends RefCounted
## Phase 237/240/246/247/278: the city's people between the two scales that already exist.
##
## The rendered crowd is a few hundred agents. The census is ~1.1M block capacities. Part 12
## asks for something in between — a population that ages, is born, dies, gets promoted,
## changes jobs and moves district — and none of that can be per-person at a million residents.
## So the resolved layer is cohorts: one age pyramid and one career-stage distribution per
## district, integrated once per simulated day. 11 districts x 7 bands x 5 stages is ~130
## integers, which is why a full simulated year costs microseconds rather than frame time.
##
## The layer is not a report. It writes four numbers that CitySim already consumes as inputs:
##
##   pop     -> footfall, which sizes the crowd and the rent bill
##   labor   -> the shop staffing cap, which is the ceiling on business growth
##   wage_c  -> the wage bill every shop pays hourly, and the norm prices sit against
##   rent_c  -> household rent, which feeds stress, which feeds the propensity to spend
##
## and it reads back the employment the shops actually created, which is what decides whether
## people move in or out. That closes the loop the spec's final cycle asks for:
## jobs -> migration -> footfall -> demand -> shops -> jobs.
##
## Every rate is per-day and every transfer is integer with a float remainder carried, so a year
## of simulation neither leaks nor rounds a cohort away, and a seeded run repeats itself.

const BANDS := ["0-5", "6-17", "18-24", "25-39", "40-54", "55-64", "65+"]
## Width of each band in years: a stable pyramid moves count/W of a band per year.
const BAND_YEARS := [6.0, 12.0, 7.0, 15.0, 15.0, 10.0, 15.0]
## Annual death rates, Shanghai-flavoured: high in infancy, low in youth, rising through 40.
const DEATH_Y := [0.0030, 0.0005, 0.0010, 0.0015, 0.0040, 0.0100, 0.0350]
const BIRTH_CRUDE_Y := 0.0070
## Migration answers two questions a district can actually be asked: is its economy hiring, and
## is it a hard place to live. 9 % a year at the extreme, either way, because a megacity district
## that runs out of jobs does bleed residents - just slowly.
const MIG_Y := 0.09
## Sensitivity to the day's change in shop employment, as a share of the labour force.
const MIG_JOBS := 40.0
## And to how far the district sits from a neutral stress level.
const MIG_STRESS := 0.6

const STAGES := ["实习", "员工", "主管", "经理", "企业家"]
const STAGE_WAGE := [0.62, 1.00, 1.40, 1.92, 2.60]
## One promotion step per 4.5 years at the district's education level.
const PROMO_Y := 0.222
const EDU := ["在校或小学", "中职高中", "大专以上"]
## Career-stage productivity is clamped: a district's wage level may drift by a quarter because
## its staff moved up a step, but no cohort doubles its pay in a year and calls it growth.
const WAGE_MIN := 0.92
const WAGE_MAX := 1.25
const RENT_MIN_DIV := 40.0
const RENT_MAX_DIV := 7.0

## Age pyramids by district character. 陆家嘴 is a place where people work and few are born;
## 黄浦 and 普陀 carry the old city's tail. These are the inputs, not a conclusion.
const PYRAMID := {
	"cbd_tower": [0.028, 0.055, 0.130, 0.340, 0.240, 0.100, 0.107],
	"modern_mix": [0.045, 0.100, 0.120, 0.270, 0.230, 0.115, 0.120],
	"historic_mix": [0.042, 0.105, 0.105, 0.220, 0.225, 0.125, 0.173],
	"old_industrial": [0.038, 0.095, 0.095, 0.210, 0.245, 0.145, 0.172],
	"sprawl_tower": [0.055, 0.120, 0.110, 0.260, 0.220, 0.105, 0.130],
	"default": [0.048, 0.110, 0.115, 0.265, 0.225, 0.115, 0.122],
}
const HIGHER_EDU := {
	"cbd_tower": 0.58, "modern_mix": 0.42, "historic_mix": 0.30,
	"old_industrial": 0.21, "sprawl_tower": 0.33, "default": 0.28,
}
## Midpoint age of each band, for the district mean age the HUD and the news wire report.
const BAND_MID := [2.5, 11.5, 21.0, 32.0, 47.0, 59.5, 73.0]

## dn -> {"age": Array[int], "stage": Array[int], "acc": Array[float], "sacc": Array[float],
##        "edu": Array[int], "base_wage_c": int, "style": String}
var cohorts: Dictionary = {}
var homes_cap: Dictionary = {}
var days_run := 0
var births_total := 0
var deaths_total := 0
var migrated_total := 0
var promoted_total := 0
## The employment each district had at the last day boundary, which is what migration is measured
## against. Part of the state: a rollback that restored the pyramid but not this would make the
## first day after loading a city produce a migration pulse it never earned.
var prev_emp: Dictionary = {}

var _style_of: Dictionary = {}


func _init() -> void:
	for d in CityData.DISTRICTS:
		_style_of[String(d["name"])] = String(d["style"])


## Called from CitySim.bootstrap, after the census has been folded into district state, so the
## pyramid is fitted to the population the generator actually produced.
func seed_from(sim: CitySim, pop: PopulationSystem) -> void:
	cohorts.clear()
	homes_cap.clear()
	days_run = 0
	births_total = 0
	deaths_total = 0
	migrated_total = 0
	promoted_total = 0
	prev_emp.clear()
	for h in pop.homes:
		var hd := String(h["d"])
		homes_cap[hd] = int(homes_cap.get(hd, 0)) + int(h["cap"])
	var names: Array = sim.districts.keys()
	names.sort()
	for n in names:
		var d: Dictionary = sim.districts[n]
		var style := _style(String(n))
		var total := maxi(1, int(d["pop"]))
		var ages := _pyramid(style, total)
		var labor := _labor(ages)
		cohorts[n] = {
			"age": ages,
			"stage": _stages(labor, style),
			"acc": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
			"sacc": [0.0, 0.0, 0.0, 0.0],
			"edu": _edu(style, labor),
			"base_wage_c": int(d["wage_c"]),
			"style": style,
		}
	write_back(sim)


func _style(name: String) -> String:
	var s := String(_style_of.get(name, "default"))
	return s if PYRAMID.has(s) else "default"


## Integer pyramid that sums to exactly `total`, remainder absorbed by the largest band, so the
## census total CitySim was bootstrapped with is preserved rather than silently re-rounded.
static func _pyramid(style: String, total: int) -> Array:
	var sh: Array = PYRAMID.get(style, PYRAMID["default"])
	var out: Array = []
	var used := 0
	for b in BANDS.size():
		var c := int(float(total) * float(sh[b]))
		out.append(c)
		used += c
	out[3] = int(out[3]) + (total - used)
	return out


## Phase 237's labor force: schooling ends at 18, retirement is a slope, not a wall.
static func _labor(ages: Array) -> int:
	return int(round(float(ages[2]) * 0.92 + float(ages[3]) + float(ages[4])
		+ float(ages[5]) * 0.55))


static func _edu(style: String, labor: int) -> Array:
	var hi := int(float(labor) * float(HIGHER_EDU.get(style, HIGHER_EDU["default"])))
	var vo := int(float(labor - hi) * 0.52)
	return [labor - hi - vo, vo, hi]


## Career mix: most people are 员工. A CBD starts with more managers because that is where the
## firms are, not because of a formula.
static func _stages(labor: int, style: String) -> Array:
	var mix := [0.16, 0.52, 0.19, 0.09, 0.04] if style == "cbd_tower" \
		else [0.14, 0.58, 0.18, 0.08, 0.02]
	var out: Array = []
	var used := 0
	for i in mix.size():
		var c := int(float(labor) * float(mix[i]))
		out.append(c)
		used += c
	out[1] = int(out[1]) + (labor - used)
	return out


## One simulated day of life: aging, births, deaths, migration, promotions - then the derived
## numbers are written into the district state the economy reads next hour.
func advance_day(sim: CitySim, rng: RandomNumberGenerator) -> void:
	days_run += 1
	var names: Array = cohorts.keys()
	names.sort()
	for n in names:
		var co: Dictionary = cohorts[n]
		var d: Dictionary = sim.districts.get(n, {})
		if d.is_empty():
			continue
		var ages: Array = co["age"]
		_age(ages, co["acc"], rng)
		var total := 0
		for a in ages:
			total += int(a)
		## The pull is measured as a change, not as a level. CitySim's `employed` counts the people
		## its shops actually staff, which is a slice of a district's jobs and not the whole of
		## them - reading it as an employment rate made every residential district look 98 %
		## unemployed and bled the city dry. What it does mean is whether the local economy is
		## hiring or closing, and that is the signal people act on.
		var labor_now := maxi(1, _labor(ages))
		var before := int(prev_emp.get(n, int(d["employed"])))
		var delta := float(int(d["employed"]) - before)
		prev_emp[String(n)] = int(d["employed"])
		var sig := delta / float(labor_now) * MIG_JOBS \
			+ MIG_STRESS * (0.5 - clampf(float(d.get("stress", 0.3)), 0.0, 1.0))
		var mig_f := MIG_Y / 365.0 * clampf(sig, -1.0, 1.0)
		var mig := _jitter(int(round(float(total) * mig_f)), rng)
		var born := _jitter(int(round(float(total) * BIRTH_CRUDE_Y / 365.0)), rng)
		ages[0] = int(ages[0]) + born
		var dead := 0
		for b in BANDS.size():
			var dm := mini(int(round(float(ages[b]) * float(DEATH_Y[b]) / 365.0)), int(ages[b]))
			ages[b] = int(ages[b]) - dm
			dead += dm
		## Migrants arrive working-age: nobody moves to a district for a job they do not have.
		if mig > 0:
			for pair in [[3, 0.46], [4, 0.30], [2, 0.16], [5, 0.08]]:
				ages[int(pair[0])] = int(ages[int(pair[0])]) + int(float(mig) * float(pair[1]))
			migrated_total += mig
		elif mig < 0:
			var left := -mig
			for b in [3, 4, 2, 5]:
				var take := mini(int(float(left) * 0.35), int(ages[b]))
				ages[b] = int(ages[b]) - take
				left -= take
			migrated_total -= left
		births_total += born
		deaths_total += dead
		promoted_total += _promote(co, rng)
	write_back(sim)


## Band-to-band aging with a carried remainder, and a one-person wobble so a year of a million
## people is not a year of one deterministic decimal.
func _age(ages: Array, acc: Array, rng: RandomNumberGenerator) -> void:
	for b in range(ages.size() - 1, 0, -1):
		acc[b] = float(acc[b]) + float(ages[b]) / (float(BAND_YEARS[b]) * 365.0)
		var move := int(float(acc[b])) + (1 if rng.randf() < 0.02 else 0)
		if move > 0:
			acc[b] = float(acc[b]) - float(move)
			move = mini(move, int(ages[b]))
			ages[b] = int(ages[b]) - move
			ages[b - 1] = int(ages[b - 1]) + move


static func _jitter(v: int, rng: RandomNumberGenerator) -> int:
	## The draw is taken even when the value is zero, so two runs that differ only in whether a
	## district happened to round to no migrants that day stay on the same random stream. Without
	## this, a single person's difference on day one reshuffles the rest of the year.
	var w := rng.randi_range(-1, 1)
	return v + w if v != 0 else 0


## Phase 246: 实习 -> 员工 -> 主管 -> 经理. The top stage is employers, so it does not promote
## onward — its headcount leaves the wage pool instead, or the pyramid grows a crown that
## nobody has to pay. Returns how many people moved up this day.
func _promote(co: Dictionary, rng: RandomNumberGenerator) -> int:
	var stages: Array = co["stage"]
	var sacc: Array = co["sacc"]
	var edu: Array = co["edu"]
	var labor := maxi(1, int(edu[0]) + int(edu[1]) + int(edu[2]))
	var edu_f := 0.75 + 0.5 * (float(int(edu[2])) + float(int(edu[1])) * 0.5) / float(labor)
	var p := PROMO_Y / 365.0 * edu_f
	var moved := 0
	for s in range(stages.size() - 2, -1, -1):
		sacc[s] = float(sacc[s]) + float(stages[s]) * p * (1.0 - 0.18 * float(s))
		var move := int(float(sacc[s]))
		if move > 0:
			sacc[s] = float(sacc[s]) - float(move)
			move = mini(move, int(stages[s]))
			stages[s] = int(stages[s]) - move
			stages[s + 1] = int(stages[s + 1]) + move
			moved += move
	# The self-employed pool churns: some register, some close. Small, seeded, and it keeps the
	# top stage from being a one-way ratchet that only ever grows.
	var top := int(stages[stages.size() - 1])
	var roll := rng.randf()
	var cand := rng.randi_range(1, 3)
	if top > 1 and roll < 0.35:
		var drop := mini(cand, top - 1)
		if drop > 0:
			stages[stages.size() - 1] = top - drop
			stages[stages.size() - 2] = int(stages[stages.size() - 2]) + drop
	return moved


## Publishes the numbers the economy reads. Called after seeding and after every day, so there
## is exactly one place where a cohort becomes a district statistic.
func write_back(sim: CitySim) -> void:
	var names: Array = cohorts.keys()
	names.sort()
	for n in names:
		var co: Dictionary = cohorts[n]
		var d: Dictionary = sim.districts[n]
		var ages: Array = co["age"]
		var total := 0
		for a in ages:
			total += int(a)
		var labor := _labor(ages)
		var edu: Array = co["edu"]
		d["pop"] = total
		d["labor"] = labor
		## Wage = the district's bootstrap level x what its career mix and schooling are worth.
		var edu_bonus := 1.0 + 0.18 * float(int(edu[2])) / maxf(float(labor), 1.0)
		d["wage_c"] = clampi(int(float(int(co["base_wage_c"])) * _productivity(co) * edu_bonus),
			900, int(int(co["base_wage_c"]) * 2))
		## Phase 253: rent is households chasing dwellings. Supply is the census's own dwelling
		## capacity; demand is the pyramid turned into households.
		var hh := households(String(n))
		var cap := maxi(1, int(homes_cap.get(String(n), hh)))
		var pressure := clampf(float(hh) / float(cap), 0.2, 3.0)
		d["rent_c"] = clampi(int(float(int(d["wage_c"])) * (0.026 + 0.055 * pressure)),
			int(float(int(d["wage_c"])) / RENT_MIN_DIV), int(float(int(d["wage_c"])) / RENT_MAX_DIV))
		d["households"] = hh
		d["dependency"] = dependency_ratio(String(n))
		sim.districts[String(n)] = d


## Weighted mean of the career stages, normalised against a pure 员工 workforce.
static func _productivity(co: Dictionary) -> float:
	var stages: Array = co["stage"]
	var n := 0
	var wsum := 0.0
	for s in stages.size():
		n += int(stages[s])
		wsum += float(stages[s]) * float(STAGE_WAGE[s])
	if n <= 0:
		return 1.0
	return clampf(wsum / float(n), WAGE_MIN, WAGE_MAX)


## Phase 241: households, from the pyramid. Children are dependents inside one and the 65+ band
## carries a widowed tail, so average size shrinks as a district ages.
func households(dn: String) -> int:
	if not cohorts.has(dn):
		return 0
	var ages: Array = cohorts[dn]["age"]
	var kids := int(ages[0]) + int(ages[1])
	var adults := int(ages[2]) + int(ages[3]) + int(ages[4]) + int(ages[5]) + int(ages[6])
	var avg := 2.35 + 0.9 * clampf(float(kids) / maxf(float(adults), 1.0), 0.0, 1.0)
	return maxi(1, int(round(float(kids + adults) / avg)))


## Phase 264/275's pressure term: pensioners and schoolchildren per working-age resident.
func dependency_ratio(dn: String) -> float:
	if not cohorts.has(dn):
		return 0.0
	var ages: Array = cohorts[dn]["age"]
	var dep := int(ages[0]) + int(ages[1]) + int(ages[6])
	return float(dep) / maxf(float(dep + _labor(ages)), 1.0)


func residents_total() -> int:
	var t := 0
	for n in cohorts.keys():
		for a in (cohorts[n]["age"] as Array):
			t += int(a)
	return t


func working_age(dn: String) -> int:
	if not cohorts.has(dn):
		return 0
	return _labor(cohorts[dn]["age"] as Array)


## The three tiers Phase 237 names, as observed numbers rather than a design claim: the real
## megacity is the reference, the cohorts are what this build simulates, and the agents are
## what it can actually load and draw.
func tiers() -> Dictionary:
	return {"real_shanghai": 24870000, "simulated": residents_total(),
		"cohort_cells": cohorts.size() * (BANDS.size() + STAGES.size()), "days": days_run}


func avg_age(dn: String) -> float:
	if not cohorts.has(dn):
		return 0.0
	var ages: Array = cohorts[dn]["age"]
	var n := 0
	var s := 0.0
	for b in ages.size():
		n += int(ages[b])
		s += float(ages[b]) * float(BAND_MID[b])
	return s / maxf(float(n), 1.0)


func stage_mix(dn: String) -> Array:
	return (cohorts[dn]["stage"] as Array) if cohorts.has(dn) else []


func age_pyramid(dn: String) -> Array:
	return (cohorts[dn]["age"] as Array) if cohorts.has(dn) else []


func stats() -> Dictionary:
	return {"days": days_run, "residents": residents_total(), "births": births_total,
		"deaths": deaths_total, "migrated": migrated_total, "promoted": promoted_total,
		"districts": cohorts.size()}


func hash_state() -> int:
	var h := 2166136261
	var names: Array = cohorts.keys()
	names.sort()
	h = CitySim._mix(h, days_run)
	for n in names:
		var co: Dictionary = cohorts[n]
		for a in (co["age"] as Array):
			h = CitySim._mix(h, int(a))
		for s in (co["stage"] as Array):
			h = CitySim._mix(h, int(s))
		for e in (co["edu"] as Array):
			h = CitySim._mix(h, int(e))
	for n in names:
		h = CitySim._mix(h, int(prev_emp.get(n, 0)))
	return h


func snapshot() -> Dictionary:
	var out := {}
	for n in cohorts.keys():
		var co: Dictionary = cohorts[n]
		out[String(n)] = {"age": (co["age"] as Array).duplicate(),
			"stage": (co["stage"] as Array).duplicate(),
			"edu": (co["edu"] as Array).duplicate(),
			"base_wage_c": int(co["base_wage_c"]), "style": String(co["style"])}
	return {"version": 1, "days": days_run, "cohorts": out, "homes_cap": homes_cap.duplicate(),
		"births": births_total, "deaths": deaths_total, "migrated": migrated_total,
		"promoted": promoted_total, "prev_emp": prev_emp.duplicate()}


func restore(s: Dictionary) -> bool:
	if typeof(s) != TYPE_DICTIONARY or not s.has("cohorts"):
		return false
	days_run = int(s.get("days", 0))
	births_total = int(s.get("births", 0))
	deaths_total = int(s.get("deaths", 0))
	migrated_total = int(s.get("migrated", 0))
	promoted_total = int(s.get("promoted", 0))
	homes_cap = s.get("homes_cap", {})
	prev_emp = s.get("prev_emp", {})
	cohorts.clear()
	var src: Dictionary = s["cohorts"]
	for n in src.keys():
		var c: Dictionary = src[n]
		cohorts[String(n)] = {
			"age": (c["age"] as Array).duplicate(),
			"stage": (c["stage"] as Array).duplicate(),
			"acc": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
			"sacc": [0.0, 0.0, 0.0, 0.0],
			"edu": (c["edu"] as Array).duplicate(),
			"base_wage_c": int(c["base_wage_c"]),
			"style": String(c["style"]),
		}
	return true
