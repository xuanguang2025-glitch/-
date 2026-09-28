class_name CitySim
extends Node
## The one coordinator Part 8 Phase 81 asks for: district-level city state that keeps
## running, is persisted, and is the single place money and people move between.
##
## Before this existed every system ticked itself and derived its own answer from a formula
## (PopulationSystem.active_share(hour) and friends), so nothing could influence anything
## else and none of it survived a session. Here the state is real and coupled: a rainy hour
## lowers walking, raises ride demand, moves spend into the transit category, changes shop
## profit, and after enough loss-making hours a shop closes - which removes jobs, which
## cuts household income, which cuts next hour's spend.
##
## Money accounting is deliberately strict. Every bucket transfer is written as a matched
## pair, so a closed economy's total is invariant and the soak test can prove it:
##
##   household --spend--> business --wages--> household
##   landlord  --spend-->            --rent --> landlord
##   business  --profit share------> household
##   household --rent--------------> landlord
##   business retained earnings may go negative; that is debt, and it is what closes a shop.
##
## Demand comes from balances, and the surplus above each shop's reserve returns to the
## households who spend it. Both matter: an earlier version paid wages out of nowhere and let
## the landlord bucket keep what it received, and over a simulated year the city collapsed to
## one shop per category. Conservation held the whole time, which is exactly why conservation
## alone is not enough to call an economy working.
##
## Two properties make the simulation testable rather than decorative: integer cents, and a
## seeded RNG with districts iterated in sorted order, so a run is bit-reproducible.

signal ticked

const CATS := ["food", "retail", "leisure", "transit"]
const STAFF_PER_SHOP := {"food": 5, "retail": 4, "leisure": 6, "transit": 9}
## Fraction of the cash a sector holds that it puts into the market each hour. Spending comes
## from a balance rather than from a notional income on purpose: a sector can only buy what it
## actually holds, and everything it holds arrived as somebody else's spending. That is what
## makes the loop close at any point in time instead of quietly assuming full employment.
const SPEND_RATE := 0.014
const RENT_SHARE := 0.12
const HOUSE_RENT_HOURS := 12	## households pay rent this many times a day
const OPEN_AFTER := 6			## consecutive profitable hours before another shop opens
const CLOSE_AFTER := 8			## consecutive loss-making hours before one closes
const PRICE_STEP := 0.02
## A shop's throughput, in sales an open counter can ring in an hour. Utilisation is measured
## against this, which is what makes the price a real lever rather than a label.
const UNITS_PER_SHOP_HR := 260
## Prices are bounded: unbounded compounding at PRICE_STEP per hour over a simulated year
## overflows the integer cent ledger, and no price in this model has any meaning 8 wages away.
const PRICE_MIN := 10
const PRICE_WAGE_MAX := 8
## A shop keeps a floating reserve this many hours of its own wage bill and pays out the
## surplus as profit share. Without that payout the business bucket is a sink: revenue arrives
## and wages and rent leave, so after a few simulated weeks nobody holds cash, demand
## collapses, and the whole city spirals down to the one-shop floor. That collapse is what
## the first version of this file did over a simulated year, and it was a modelling error, not
## an emergent outcome.
const RESERVE_HOURS := 24.0
## Crew size used to translate a labour pool into how many shops a district could staff.
const STAFF_AVG := 6.0
## How much of the labour pool shop growth may ever absorb. Keeps employment from being
## unlimited, which would make the wage bill outrun demand and invert the collapse.
const EMPLOY_CAP := 0.85
## Demand elasticity against a shop's own price, around the wage-implied norm price of
## wage_c / 40. Prices only matter because something reads them.
const PRICE_NORM := 40.0
const PRICE_ELAST := 0.9
## Dry-day share of households that want a ride. Everything the traffic system scales
## against is normalised to this, so a clear morning looks exactly as busy as it did before
## the simulation was wired in and only genuine demand changes move the street.
const RIDE_BASE := 0.12

var hours_run := 0
var day := 1
var districts: Dictionary = {}	# name -> state
var events: Array = []			# recent open/close records (Phase 98)
var seed_base := 20260928
var _rng := RandomNumberGenerator.new()
var _streak: Dictionary = {}
var _clock: Callable = func() -> float: return 9.0
var _rain: Callable = func() -> float: return 0.0
var _share: Callable = func(_h: float) -> float: return 0.5


## Consumers (crowd, traffic) resolve this by group rather than by an assignment in
## GameRoot, so a system instantiated on its own still finds the city instead of silently
## running with a factor of 1.0 and looking like it is wired up when it is not.
func _ready() -> void:
	add_to_group("sim")


func configure(clock: Callable, rain: Callable, share: Callable) -> void:
	_clock = clock
	_rain = rain
	_share = share


## Builds the initial state from the census, so the simulation inherits the city the
## generator actually made instead of a hand-typed population table.
func bootstrap(pop: PopulationSystem) -> void:
	_rng.seed = seed_base
	districts.clear()
	_streak.clear()
	events.clear()
	hours_run = 0
	day = 1
	var names: Array = pop.district_pop.keys()
	names.sort()
	var wage := _avg_wage_c()
	## footfall and ride demand are outputs of _step(), so before the first tick they would
	## read as zero — and the crowd would boot at its 0.35 floor and look like a broken
	## simulation rather than an un-started one. Seed them from the current hour.
	var hour: float = _clock.call()
	var rain: float = _rain.call()
	var share := clampf(_share.call(hour), 0.0, 1.0)
	for n in names:
		var people: int = int(pop.district_pop[n])
		if people <= 0:
			continue
		var shops := {}
		for c in CATS:
			var per: float = 900.0 if c == "food" else 1400.0 if c == "retail" \
				else 2600.0 if c == "leisure" else 1800.0
			shops[c] = {"count": maxi(1, int(people / per)), "price_c": int(wage / 40),
				"bank_c": people * int(wage) / 20, "last_profit_c": 0, "util": 0.6}
		districts[n] = {
			"pop": people,
			"labor": int(people * 0.62),
			"employed": 0,
			"wage_c": wage,
			"rent_c": int(wage / 22),
			"house_c": people * wage * 30,
			"land_c": people * wage * 4,
			"shops": shops,
			"stress": 0.25,
			"footfall": int(round(float(people) * share)),
			"ride_demand": ride_demand(rain),
		}
		_streak[n] = {}
		for c in CATS:
			_streak[n][c] = 0
	reconcile_jobs()


## Weather -> mobility demand, in one place so bootstrap and every tick agree on it.
static func ride_demand(rain: float) -> float:
	return clampf(0.12 + 0.5 * rain, 0.0, 0.75)


func _avg_wage_c() -> int:
	## Derived from the same occupation table the NPCs use, weighted by hiring share, and
	## converted from monthly CNY to an hourly cent figure (730 h month).
	var tot := 0.0
	var wsum := 0
	for k in OccupationTable.DATA.keys():
		var d: Dictionary = OccupationTable.DATA[k]
		tot += float(d["income"]) * int(d["weight"])
		wsum += int(d["weight"])
	return maxi(1200, int(maxf(1200.0, tot / maxf(float(wsum), 1.0)) * 100.0 / 730.0))


## One simulated hour. Called at low frequency (Phase 109), never per frame.
func advance_hour() -> void:
	hours_run += 1
	if hours_run % 24 == 0:
		day += 1
	# Callable.call() hands back a Variant, so these must be annotated rather than inferred.
	var hour: float = _clock.call()
	var rain: float = _rain.call()
	var share: float = clampf(_share.call(hour), 0.0, 1.0)
	var names: Array = districts.keys()
	names.sort()
	for n in names:
		_step(districts[n], n, rain, share)
	reconcile_jobs()
	ticked.emit()


func advance_hours(n: int) -> void:
	for i in n:
		advance_hour()


func _step(d: Dictionary, name: String, rain: float, share: float) -> void:
	var active: int = maxi(0, int(round(float(d["pop"]) * share)))
	d["footfall"] = active
	## Phase 99: weather moves demand between categories rather than only tinting the sky.
	var ride := ride_demand(rain)
	d["ride_demand"] = ride
	var labor: int = maxi(1, int(d["labor"]))
	var unemp := clampf(1.0 - float(int(d["employed"])) / float(labor), 0.0, 1.0)
	## Phase 89: joblessness and stress cut the willingness to spend, not a notional income.
	var prop := SPEND_RATE * (1.0 - 0.45 * unemp) * (1.0 - 0.25 * float(d["stress"]))
	# Both cash-holding sectors buy. Rent is only a transfer between sectors, so if landlords
	# accumulated it instead of spending it, that money would leave circulation for good.
	var hspend: int = mini(int(int(d["house_c"]) * prop), int(d["house_c"]))
	var lspend: int = mini(int(int(d["land_c"]) * SPEND_RATE), int(d["land_c"]))
	d["house_c"] = int(d["house_c"]) - hspend
	d["land_c"] = int(d["land_c"]) - lspend
	var budget: int = hspend + lspend
	var w := {"food": 0.34, "retail": 0.24, "leisure": 0.20, "transit": 0.22}
	w["transit"] = w["transit"] * (1.0 + 1.8 * rain)
	w["leisure"] = w["leisure"] * (1.0 - 0.45 * rain)
	w["food"] = w["food"] * (1.0 + 0.15 * rain)
	## Prices feed back into demand, so the price that utilisation moves below is a real
	## price rather than a number that only exists to be hashed.
	for c in CATS:
		var pc: float = float(d["shops"][c]["price_c"])
		w[c] = float(w[c]) * clampf(pow(float(d["wage_c"]) / maxf(pc * PRICE_NORM, 1.0),
			PRICE_ELAST), 0.35, 2.4)
	var norm := 0.0
	for c in CATS:
		norm += w[c]
	var left := budget
	for ci in CATS.size():
		var c: String = CATS[ci]
		var part: int
		if ci == CATS.size() - 1:
			part = left
		else:
			part = int(round(budget * float(w[c]) / maxf(norm, 0.0001)))
			part = mini(part, left)
		left -= part
		_market(d, name, c, part)
	# Households pay rent to landlords directly; a matched house -> land transfer.
	var hrent: int = mini(int(d["pop"]) * int(d["rent_c"]) / HOUSE_RENT_HOURS, int(d["house_c"]))
	d["house_c"] = int(d["house_c"]) - hrent
	d["land_c"] = int(d["land_c"]) + hrent
	d["stress"] = clampf(0.35 * unemp + 0.45 * clampf(float(d["rent_c"])
		/ maxf(float(d["wage_c"]) * 0.5, 1.0), 0.0, 1.0) + 0.2 * float(d["stress"]), 0.0, 1.0)


## One category's market for this hour. Every line here is a transfer between two buckets,
## never a value appearing from nowhere.
func _market(d: Dictionary, name: String, c: String, spend: int) -> void:
	var s: Dictionary = d["shops"][c]
	var count: int = maxi(1, int(s["count"]))
	var wages: int = count * int(STAFF_PER_SHOP[c]) * int(d["wage_c"])
	var rent: int = int(spend * RENT_SHARE)
	s["bank_c"] = int(s["bank_c"]) + spend - wages - rent
	d["house_c"] = int(d["house_c"]) + wages
	d["land_c"] = int(d["land_c"]) + rent
	# Retained earnings may go negative - that debt is what eventually closes the shop.
	var profit: int = spend - wages - rent
	s["last_profit_c"] = profit
	# Profit share: anything a shop holds above a floating reserve of its own wage bill goes
	# back to the households who will spend it. A loss-making shop burns the reserve instead
	# and runs into debt, which is the pressure that closes it below.
	var reserve: int = int(wages * RESERVE_HOURS)
	if int(s["bank_c"]) > reserve:
		var div: int = int(s["bank_c"]) - reserve
		s["bank_c"] = reserve
		d["house_c"] = int(d["house_c"]) + div
	var capacity: int = count * UNITS_PER_SHOP_HR
	## Utilisation is units the till actually rang, not heads in the district: revenue divided
	## by the price gives units, and that over the shop's hourly throughput is what tells the
	## owner whether to charge more. Comparing an hourly headcount to a daily capacity, as the
	## first version did, left every category permanently "empty" and prices never moved.
	var util := clampf(float(spend) / maxf(float(s["price_c"]) * float(capacity), 1.0), 0.0, 1.6)
	s["util"] = util
	# roundi, not int: truncating a 2 % step at a small price yields the same price (32 * 1.02
	# is 32.6, and int() of that is 32), so every category sat at its bootstrap price forever
	# and the price field was decorative while looking live in every dump of the state.
	if util > 0.95:
		s["price_c"] = clampi(roundi(float(s["price_c"]) * (1.0 + PRICE_STEP)),
			PRICE_MIN, int(d["wage_c"]) * PRICE_WAGE_MAX)
	elif util < 0.35:
		s["price_c"] = clampi(roundi(float(s["price_c"]) * (1.0 - PRICE_STEP)),
			PRICE_MIN, int(d["wage_c"]) * PRICE_WAGE_MAX)
	d["shops"][c] = s
	var k: int = int(_streak[name][c])
	if profit > 0:
		k = maxi(1, k + 1)
	elif profit < 0:
		k = mini(-1, k - 1)
	else:
		k = 0
	_streak[name][c] = k
	# Churn is the visible output of the coupling: enough good hours opens a shop, enough
	# bad ones closes it, and both move the job count next hour's income depends on.
	if k >= OPEN_AFTER and count < _cap(d):
		s["count"] = count + 1
		_streak[name][c] = 0
		_event("OPEN", name, c, count + 1)
	elif k <= -CLOSE_AFTER and count > 1:
		s["count"] = count - 1
		_streak[name][c] = 0
		_event("CLOSE", name, c, count - 1)


## How many shops of one category a district could staff at all. Growth stops here rather
## than at a constant that happened to look reasonable on the day the file was written.
func _cap(d: Dictionary) -> int:
	var jobs := int(int(d["labor"]) * EMPLOY_CAP)
	return maxi(4, int(float(jobs) / STAFF_AVG / float(CATS.size())))


func _event(kind: String, district: String, cat: String, count: int) -> void:
	events.append({"hour": hours_run, "kind": kind, "district": district,
		"cat": cat, "count": count})
	if events.size() > 200:
		events.pop_front()


## Employment follows the shops that actually exist, so it is a consequence of business
## churn rather than an independent number that could drift away from it.
func reconcile_jobs() -> void:
	for n in districts.keys():
		var d: Dictionary = districts[n]
		var jobs := 0
		for c in CATS:
			jobs += int(d["shops"][c]["count"]) * int(STAFF_PER_SHOP[c])
		d["employed"] = clampi(jobs, 0, int(d["labor"]))


## Phase 104: a player action enters the simulation as supply and demand, not as a direct
## edit of some actor. Returns what changed so the caller can report it honestly.
func apply_player_action(kind: String, at: Vector2) -> Dictionary:
	var name := district_at(at)
	if not districts.has(name):
		return {"ok": false, "why": "无此区域"}
	var d: Dictionary = districts[name]
	var s: Dictionary = d["shops"]["retail"]
	match kind:
		"open_shop":
			s["count"] = int(s["count"]) + 1
			d["shops"]["retail"] = s
			_event("PLAYER_OPEN", name, "retail", int(s["count"]))
			reconcile_jobs()
			return {"ok": true, "district": name, "count": int(s["count"])}
		"close_shop":
			if int(s["count"]) <= 1:
				return {"ok": false, "why": "该区域已无商铺可关"}
			s["count"] = int(s["count"]) - 1
			d["shops"]["retail"] = s
			_event("PLAYER_CLOSE", name, "retail", int(s["count"]))
			reconcile_jobs()
			return {"ok": true, "district": name, "count": int(s["count"])}
		_:
			return {"ok": false, "why": "未知行为 " + kind}


func district_at(p: Vector2) -> String:
	return String(CityData.district_at(p)["name"])


# --- Consumers: where the simulation reaches the rendered world -------------
## These are read every frame by the crowd and traffic systems, so a shop closing upstream
## visibly thins the street downstream. They are multipliers on the existing per-frame
## budget rather than a second source of truth: a district the simulation does not know
## about returns 1.0 and the street behaves exactly as it did before Phase 81.
func crowd_factor(name: String) -> float:
	var d: Dictionary = districts.get(name, {})
	if d.is_empty():
		return 1.0
	return clampf(0.35 + 0.65 * float(d["footfall"]) / maxf(float(d["pop"]), 1.0), 0.2, 1.3)


## How many vehicles this district should show. Rides are what rain buys, so demand rises
## with it - but the vehicle budget is a hard frame-cost limit, so the multiplier saturates
## instead of trading the performance gate away for realism.
func car_factor(name: String) -> float:
	var d: Dictionary = districts.get(name, {})
	if d.is_empty():
		return 1.0
	return clampf(0.55 + 0.45 * float(d["ride_demand"]) / RIDE_BASE, 0.55, 1.35)


func ride_factor(name: String) -> float:
	var d: Dictionary = districts.get(name, {})
	return float(d.get("ride_demand", RIDE_BASE))


## Position-taking forms, so a consumer does not have to know that districts are named.
func crowd_factor_at(p: Vector2) -> float:
	return crowd_factor(district_at(p))


func car_factor_at(p: Vector2) -> float:
	return car_factor(district_at(p))


func total_employment() -> int:
	var t := 0
	for n in districts:
		t += int(districts[n]["employed"])
	return t


func total_shops() -> int:
	var t := 0
	for n in districts:
		for c in CATS:
			t += int(districts[n]["shops"][c]["count"])
	return t


func house_total() -> int:
	var s := 0
	for n in districts:
		s += int(districts[n]["house_c"])
	return s


func land_total() -> int:
	var s := 0
	for n in districts:
		s += int(districts[n]["land_c"])
	return s


func business_total() -> int:
	var s := 0
	for n in districts:
		for c in CATS:
			s += int(districts[n]["shops"][c]["bank_c"])
	return s


## Every bucket in the closed economy. A tick must not change this by even one cent.
func money_total() -> int:
	return house_total() + land_total() + business_total()


func state_hash() -> int:
	var h := 2166136261
	for n in _sorted_names():
		var d: Dictionary = districts[n]
		h = _mix(h, int(d["house_c"]))
		h = _mix(h, int(d["land_c"]))
		h = _mix(h, int(d["employed"]))
		h = _mix(h, int(round(float(d["stress"]) * 1000.0)))
		for c in CATS:
			var s: Dictionary = d["shops"][c]
			h = _mix(h, int(s["count"]))
			h = _mix(h, int(s["bank_c"]))
			h = _mix(h, int(s["price_c"]))
	return h


func _sorted_names() -> Array:
	var a: Array = districts.keys()
	a.sort()
	return a


static func _mix(h: int, v: int) -> int:
	h = h ^ (v & 0x7fffffff)
	h = (h * 16777619) & 0x7fffffff
	return h


# --- Phase 110/111: persistence, snapshots, rollback ------------------------
func snapshot() -> Dictionary:
	return {"version": 1, "hours_run": hours_run, "day": day, "seed": seed_base,
		"districts": districts.duplicate(true), "events": events.slice(-50)}


func restore(s: Dictionary) -> bool:
	if typeof(s) != TYPE_DICTIONARY or not s.has("districts"):
		return false
	hours_run = int(s.get("hours_run", 0))
	day = int(s.get("day", 1))
	seed_base = int(s.get("seed", seed_base))
	districts = s["districts"]
	events = s.get("events", [])
	for n in districts.keys():
		if not _streak.has(n):
			_streak[n] = {}
		for c in CATS:
			if not _streak[n].has(c):
				_streak[n][c] = 0
	return true


func stats() -> Dictionary:
	return {"hours": hours_run, "day": day, "districts": districts.size(),
		"shops": total_shops(), "employed": total_employment(),
		"money": money_total(), "events": events.size()}
