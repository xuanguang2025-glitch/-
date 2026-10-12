class_name NPCProfile
extends RefCounted
## One resident. Identity, needs and a day plan — the layer that decides where a crowd
## agent is going and why, so movement stops being random wandering.
##
## Deliberately cheap: needs integrate once per sim tick and only for agents the player
## could plausibly interact with (AI tier 0). Further away, the plan still drives movement
## but the needs freeze, which is the whole point of the tiering.

var id: int = 0
var display_name: String = ""
var age: int = 30
var occ: int = 0
var home: Vector2 = Vector2.ZERO
var work: Vector2 = Vector2.ZERO
var has_job: bool = false

var state: int = OccupationTable.State.SLEEP
var goal_kind: String = "home"
var goal_hint: Vector2 = Vector2.ZERO
## Actual world position the crowd navigates toward, resolved from goal_kind.
var goal: Vector2 = Vector2.ZERO

## 0 = starved/dead-tired, 1 = fully satisfied.
var food: float = 0.8
var sleep: float = 0.9
var money: float = 0.5
var social: float = 0.7
var fun: float = 0.6
var health: float = 0.95

## What the player has done to or for this person. Persisted later with the save system.
var memory: Dictionary = {}
var mood: float = 0.6

var income: float = 0.0

## --- Part 12: the parts of a person that make two of them different ------------------
## Phase 239's personality vector. Six axes, all 0..1, rolled once at creation and never
## re-rolled. They exist because without them the plan, the walk and the purchase of an office
## worker are a function of the clock alone, and every 白领 on 南京路 would do the same thing at
## the same minute. With them, 工作狂 stays late, 外向 turns out in the evening whatever the
## weather does, and 消费欲 decides which shop a hungry person is willing to walk further for.
var personality: Dictionary = {}
## Phase 238's remaining identity fields. `education` and `seniority` index the same tables the
## cohort model uses, so a named person and the district statistic they came from agree.
var education: int = 1
var seniority: int = 1
var household: int = 3
## Phase 268: ids of the people this one actually knows, for as long as the build can name them.
var friends: Array = []
## Real cents in this pocket. Credited by ConsumerAI out of the district's wage bill and spent at
## a counter. `money` above stays the 0..1 need it always was; this is the balance, in integer
## cents, in the ledger's fourth bucket.
var purse_c: int = 0
var income_hour_c: int = 0
var buys: int = 0
var spent_c: int = 0
var last_buy_hidx: int = -1


## Phase 240's visible stage of life, derived from age rather than stored, so it cannot disagree.
func life_stage() -> String:
	if age < 6:
		return "幼年"
	if age < 18:
		return "中学"
	if age < 23:
		return "大学或初入职场"
	if age < 40:
		return "职业上升"
	if age < 60:
		return "资深在职"
	return "退休"


func stage_label() -> String:
	var st: Array = VirtualPopulation.STAGES
	return String(st[clampi(seniority, 0, st.size() - 1)])


func persona(key: String) -> float:
	return float(personality.get(key, 0.5))


static func create(pid: int, rnd: RandomNumberGenerator, pop: PopulationSystem,
		near: Vector2) -> NPCProfile:
	var p := NPCProfile.new()
	p.id = pid
	p.occ = OccupationTable.roll(rnd)
	p.display_name = OccupationTable.make_name(rnd)
	p.age = OccupationTable.make_age(p.occ, rnd)
	p.income = OccupationTable.income(p.occ)
	p.money = 0.25 + rnd.randf() * 0.6
	p.food = 0.45 + rnd.randf() * 0.5
	p.sleep = 0.5 + rnd.randf() * 0.5
	p.social = 0.35 + rnd.randf() * 0.6
	p.fun = 0.3 + rnd.randf() * 0.6
	p.health = 0.7 + rnd.randf() * 0.3
	p.home = pop.pick_home(near, rnd)
	p.has_job = OccupationTable.is_worker(p.occ) and p.occ != OccupationTable.Occ.TOURIST
	if p.has_job:
		p.work = pop.pick_job(OccupationTable.zone(p.occ), p.home, rnd)
	else:
		p.work = p.home
	p.income_hour_c = int(p.income * 100.0 / 730.0)
	p.personality = _personality(p.occ, p.age, rnd)
	p.education = _education(p.occ, p.age, rnd)
	p.seniority = _seniority(p.occ, p.age, p.education, rnd)
	p.household = 1 + rnd.randi_range(2, 4)
	p.plan(rnd.randf() * 24.0, 0.0, pop)
	p._sync_goal(pop)
	return p


## Phase 239, as data: an occupation starts with a disposition and a life stage narrows it. A
## 65-year-old 退休 is not a 30-year-old 白领 with a different schedule, and the vector is where
## that shows up before any behaviour is derived from it.
static func _personality(occ: int, age: int, rnd: RandomNumberGenerator) -> Dictionary:
	var base := {"extravert": 0.5, "rational": 0.5, "thrill": 0.5, "spend": 0.5,
		"workaholic": 0.5, "social": 0.5}
	match occ:
		OccupationTable.Occ.OFFICE, OccupationTable.Occ.ENGINEER:
			base["workaholic"] = 0.66
			base["rational"] = 0.62
		OccupationTable.Occ.SHOPKEEPER, OccupationTable.Occ.FREELANCE:
			base["extravert"] = 0.68
			base["spend"] = 0.58
		OccupationTable.Occ.STUDENT:
			base["thrill"] = 0.72
			base["social"] = 0.70
			base["spend"] = 0.34
		OccupationTable.Occ.DOCTOR, OccupationTable.Occ.POLICE:
			base["workaholic"] = 0.72
			base["rational"] = 0.68
		OccupationTable.Occ.DRIVER, OccupationTable.Occ.WORKER, OccupationTable.Occ.CLEANER, \
		OccupationTable.Occ.GUARD:
			base["spend"] = 0.40
			base["rational"] = 0.56
		OccupationTable.Occ.RETIRED:
			base["social"] = 0.66
			base["workaholic"] = 0.20
			base["thrill"] = 0.26
		OccupationTable.Occ.TOURIST:
			base["thrill"] = 0.80
			base["spend"] = 0.72
	if age > 55:
		base["thrill"] = float(base["thrill"]) * 0.6
		base["spend"] = float(base["spend"]) * 0.8
	elif age < 25:
		base["rational"] = float(base["rational"]) * 0.75
	for k in base.keys():
		base[k] = clampf(float(base[k]) + rnd.randf_range(-0.14, 0.14), 0.05, 0.95)
	return base


## 0 = 初中及以下, 1 = 高中/中职, 2 = 大专以上. Correlated with occupation the same way the
## cohort layer's education mix is, so a named 医生 and the district's doctor cohort agree.
static func _education(occ: int, age: int, rnd: RandomNumberGenerator) -> int:
	var hi := 0.12
	match occ:
		OccupationTable.Occ.OFFICE, OccupationTable.Occ.ENGINEER, OccupationTable.Occ.FREELANCE:
			hi = 0.72
		OccupationTable.Occ.DOCTOR, OccupationTable.Occ.TEACHER:
			hi = 0.88
		OccupationTable.Occ.STUDENT:
			hi = 0.34 if age < 15 else 0.52
		OccupationTable.Occ.DRIVER, OccupationTable.Occ.WORKER, OccupationTable.Occ.CLEANER, \
		OccupationTable.Occ.GUARD:
			hi = 0.10
		OccupationTable.Occ.RETIRED:
			hi = 0.16
	var r := rnd.randf()
	if r < hi:
		return 2
	return 1 if r < hi + 0.46 else 0


## Phase 246's starting rung. Education shortens the time to the top, and age is the clock that
## actually ran, not a random draw — a 58-year-old 员工 with a 高中 diploma is a real person, and
## so is a 26-year-old 主管 at a startup.
static func _seniority(occ: int, age: int, edu: int, rnd: RandomNumberGenerator) -> int:
	if not OccupationTable.is_worker(occ) or occ == OccupationTable.Occ.STUDENT \
			or occ == OccupationTable.Occ.TOURIST:
		return 0
	var years := clampi(age - 22 - (2 if edu == 2 else 0), 0, 40)
	var p := 0.020 + 0.012 * float(edu)
	var s := 0
	for k in years:
		if rnd.randf() < p:
			s += 1
			p *= 0.68
	return clampi(s, 0, 4)


## What this person contributes to the district rent bill, in cents per simulated hour. Retired
## and students pay too, because households pay rent rather than paycheques; a tourist pays
## nothing here because their lodging is already booked as 休闲 spending.
##
## It is a *share*, not a second charge: CitySim's district-level rent is the whole bill, and the
## ConsumerAI settles each named resident's slice of it against the household bucket they are
## counted in, so the total the landlord receives stays the number the economy was given.
func hourly_rent_c() -> int:
	if occ == OccupationTable.Occ.TOURIST:
		return 0
	if income_hour_c <= 0:
		return 60 + int(float(seniority) * 20.0)
	var share := 0.42
	if occ == OccupationTable.Occ.CLEANER or occ == OccupationTable.Occ.GUARD \
			or occ == OccupationTable.Occ.DRIVER or occ == OccupationTable.Occ.WORKER:
		share = 0.52
	elif occ == OccupationTable.Occ.STUDENT:
		share = 0.12
	elif occ == OccupationTable.Occ.RETIRED:
		share = 0.28
	elif occ == OccupationTable.Occ.FREELANCE:
		share = 0.36
	return maxi(20, int(income_hour_c * share))


## Resolve the day plan for an hour of the day. Returns the goal class the crowd should
## navigate toward; PopulationSystem turns that into an actual position.
func plan(hour: float, rain: float, pop: PopulationSystem) -> void:
	var sh := OccupationTable.shift(occ)
	var was := state
	if not has_job:
		_plan_without_job(hour, rain)
	else:
		_plan_working(hour, rain, sh)
	if state != was:
		_sync_goal(pop)


func _plan_working(hour: float, rain: float, sh: Vector2) -> void:
	var start := sh.x
	var end := sh.y
	if hour < start - 0.75 or hour >= 23.0 or hour < 5.0:
		state = OccupationTable.State.SLEEP
	elif hour < start:
		state = OccupationTable.State.COMMUTE
	elif hour < 12.0:
		state = OccupationTable.State.WORK
	elif hour < 13.2:
		# Lunch is a walk to a shopfront near the office, not a teleport.
		state = OccupationTable.State.LUNCH
	elif hour < end:
		state = OccupationTable.State.WORK
	elif hour < end + 0.8:
		state = OccupationTable.State.COMMUTE
	elif hour < 22.4:
		state = OccupationTable.State.LEISURE if rain < 0.4 else OccupationTable.State.SHOP
	else:
		state = OccupationTable.State.SLEEP
	# A hungry or exhausted worker breaks for food rather than going home early.
	if state == OccupationTable.State.WORK and (food < 0.25 or fun < 0.15):
		state = OccupationTable.State.SHOP


func _plan_without_job(hour: float, rain: float) -> void:
	if hour < 5.6 or hour >= 22.8:
		state = OccupationTable.State.SLEEP
	elif hour < 8.0:
		# Retirees own the parks before nine; this is the most Shanghai thing there is.
		state = OccupationTable.State.EXERCISE if rain < 0.35 else OccupationTable.State.LEISURE
	elif hour < 11.5:
		state = OccupationTable.State.SHOP if occ == OccupationTable.Occ.RETIRED \
			else OccupationTable.State.LEISURE
	elif hour < 13.5:
		state = OccupationTable.State.LUNCH
	elif hour < 18.5:
		state = OccupationTable.State.LEISURE
	else:
		state = OccupationTable.State.SHOP


func _sync_goal(pop: PopulationSystem) -> void:
	match state:
		OccupationTable.State.SLEEP:
			goal_kind = "home"
			goal_hint = home
		OccupationTable.State.COMMUTE:
			# Mid-commute the goal is whichever end we are not at.
			goal_kind = "work"
			goal_hint = work
		OccupationTable.State.WORK:
			goal_kind = "work"
			goal_hint = work
		OccupationTable.State.LUNCH, OccupationTable.State.SHOP:
			goal_kind = "retail"
			goal_hint = work if state == OccupationTable.State.LUNCH else home
		OccupationTable.State.EXERCISE:
			goal_kind = "park"
			goal_hint = home
		_:
			goal_kind = "leisure"
			goal_hint = home
	if pop != null:
		goal = pop.resolve(goal_kind, goal_hint)
	else:
		goal = goal_hint


## Needs integration. Called at AI tier 0 only.
func tick(delta: float, working: bool) -> void:
	var day := delta / 480.0
	food = clampf(food - day * 1.35, 0.0, 1.0)
	sleep = clampf(sleep - day * (1.15 if not working else 0.85), 0.0, 1.0)
	social = clampf(social - day * 0.75, 0.0, 1.0)
	fun = clampf(fun - day * (0.95 if working else 0.55), 0.0, 1.0)
	health = clampf(health + day * (0.30 if sleep > 0.5 else -0.25), 0.0, 1.0)
	if state == OccupationTable.State.LUNCH or state == OccupationTable.State.SHOP:
		food = clampf(food + delta * 0.20, 0.0, 1.0)
		fun = clampf(fun + delta * 0.05, 0.0, 1.0)
		money = clampf(money - delta * 0.02, 0.0, 1.0)
	if state == OccupationTable.State.EXERCISE:
		health = clampf(health + delta * 0.10, 0.0, 1.0)
	if state == OccupationTable.State.SLEEP:
		sleep = clampf(sleep + delta * 0.22, 0.0, 1.0)
	if state == OccupationTable.State.WORK and has_job:
		money = clampf(money + delta * 0.012, 0.0, 1.0)
	mood = clampf(0.10 + 0.20 * food + 0.22 * sleep + 0.16 * social \
		+ 0.16 * fun + 0.16 * health, 0.0, 1.0)


func remember(key: String, delta: float) -> void:
	memory[key] = clampf(float(memory.get(key, 0.0)) + delta, -1.0, 1.0)
	mood = clampf(mood + delta * 0.25, 0.0, 1.0)


func feeling() -> String:
	if mood > 0.82:
		return "愉悦"
	if mood > 0.62:
		return "平静"
	if mood > 0.44:
		return "疲惫"
	if mood > 0.28:
		return "烦躁"
	return "低落"


func state_label() -> String:
	match state:
		OccupationTable.State.SLEEP: return "在家"
		OccupationTable.State.COMMUTE: return "通勤"
		OccupationTable.State.WORK: return "工作"
		OccupationTable.State.LUNCH: return "午饭"
		OccupationTable.State.LEISURE: return "休闲"
		OccupationTable.State.SHOP: return "购物"
		_: return "锻炼"
