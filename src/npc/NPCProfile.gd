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
	p.plan(rnd.randf() * 24.0, 0.0, pop)
	p._sync_goal(pop)
	return p


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
