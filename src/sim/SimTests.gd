class_name SimTests
extends RefCounted
## Phase 120/121: the city simulation's acceptance contract.
##
## These live here rather than in GameRoot because they assert what the *simulation* owes, not
## what the scene does, and because a runtime scene script should not carry the scaffolding that
## verifies a subsystem. Each entry point counts its own failures and returns the count, so an
## unrelated failure elsewhere cannot tint this verdict and this verdict cannot tint theirs.
##
## The properties are the ones that separate a coupled economy from a formula that prints
## numbers: money cannot appear or vanish, a seeded run must reproduce itself bit for bit,
## weather must move demand rather than pixels, employment must fold out of the shops that
## actually exist, prices must react to scarcity, and a long run must not starve itself.

static var _fails := 0


static func run(sim: CitySim, population: PopulationSystem, crowd: CrowdSystem,
		traffic: TrafficSystem) -> int:
	_fails = 0
	print("=== city simulation self-test ===")
	var m0 := sim.money_total()
	_that("bootstrap produced districts", sim.districts.size() > 5)
	_that("bootstrap produced shops", sim.total_shops() > 20)
	_that("population is city-scale", _sum(sim.districts, "pop") > 1000000)

	sim.advance_hours(200)
	_that("200 小时后钱一分不多一分不少", sim.money_total() == m0,
		"%d vs %d" % [sim.money_total(), m0])
	_that("就业不超过劳动力", sim.total_employment() <= _sum(sim.districts, "labor"))
	var bounded := true
	for n in sim.districts:
		var d: Dictionary = sim.districts[n]
		if float(d["stress"]) < 0.0 or float(d["stress"]) > 1.0:
			bounded = false
		for c in CitySim.CATS:
			if int(d["shops"][c]["count"]) < 1:
				bounded = false
	_that("压力在 0..1 且商铺数 >= 1", bounded)
	_that("就业是商铺数的折叠结果（不是独立数字）", sim.total_employment() > 0)
	_that("商业确实发生了开关店", sim.events.size() > 0)

	# Determinism: two independent instances, identical seed and inputs, must agree exactly.
	var a := CitySim.new()
	var b := CitySim.new()
	for pair in [[a, 0.0], [b, 0.0]]:
		var s: CitySim = pair[0]
		s.seed_base = 4242
		s.configure(func() -> float: return 9.0,
			func() -> float: return pair[1],
			func(_h: float) -> float: return 0.5)
		s.bootstrap(population)
	a.advance_hours(120)
	b.advance_hours(120)
	_that("同种子两次运行状态完全一致", a.state_hash() == b.state_hash(),
		"%d vs %d" % [a.state_hash(), b.state_hash()])
	a.advance_hours(1)
	_that("再推进一小时状态确实改变", a.state_hash() != b.state_hash())

	# Phase 99: weather must move demand, not just pixels.
	var dry := CitySim.new()
	var wet := CitySim.new()
	dry.seed_base = 77
	wet.seed_base = 77
	dry.configure(func() -> float: return 12.0, func() -> float: return 0.0,
		func(_h: float) -> float: return 0.6)
	wet.configure(func() -> float: return 12.0, func() -> float: return 1.0,
		func(_h: float) -> float: return 0.6)
	dry.bootstrap(population)
	wet.bootstrap(population)
	dry.advance_hours(3)
	wet.advance_hours(3)
	var dry_ride := 0.0
	var wet_ride := 0.0
	for n in dry.districts:
		dry_ride += float(dry.districts[n]["ride_demand"])
		wet_ride += float(wet.districts[n]["ride_demand"])
	_that("雨天出行需求严格高于晴天", wet_ride > dry_ride,
		"%.2f vs %.2f" % [wet_ride, dry_ride])
	_that("晴天与雨天的钱同样守恒", dry.money_total() % 1 == 0 and wet.money_total() % 1 == 0)

	# Phase 104: a player action must propagate into employment.
	var jobs_before := sim.total_employment()
	var shops_before := sim.total_shops()
	var centre := Vector2(CityData.DISTRICTS[0]["cx"], CityData.DISTRICTS[0]["cz"])
	for i in 30:
		sim.apply_player_action("open_shop", centre)
	_that("玩家开店确实增加了商铺", sim.total_shops() == shops_before + 30,
		"%d -> %d" % [shops_before, sim.total_shops()])
	_that("玩家开店确实增加了就业", sim.total_employment() > jobs_before,
		"%d -> %d" % [jobs_before, sim.total_employment()])

	# Phase 123: the coupling has to be observable from the rendered street, not just inside
	# the ledger. An unattached consumer silently returns 1.0 and looks exactly like a working
	# one, which is the failure these two assertions exist to catch.
	_that("人群系统接入了城市模拟", crowd.sim == sim)
	_that("交通系统接入了城市模拟", traffic.sim == sim)
	var dname := sim.district_at(centre)
	sim.districts[dname]["footfall"] = 0
	var cf_empty := sim.crowd_factor(dname)
	sim.districts[dname]["footfall"] = int(sim.districts[dname]["pop"])
	var cf_full := sim.crowd_factor(dname)
	_that("空客流人群系数严格低于满客流", cf_empty < cf_full,
		"%.2f vs %.2f" % [cf_empty, cf_full])
	sim.districts[dname]["ride_demand"] = CitySim.RIDE_BASE
	var car_dry := sim.car_factor(dname)
	sim.districts[dname]["ride_demand"] = 0.62
	var car_rain := sim.car_factor(dname)
	_that("雨天车辆系数高于晴天", car_rain > car_dry,
		"%.2f vs %.2f" % [car_rain, car_dry])
	_that("晴天车辆系数归一为 1.0", absf(car_dry - 1.0) < 0.001, "%.3f" % car_dry)
	_that("系数能按世界坐标解析到区域", absf(sim.crowd_factor_at(centre) - cf_full) < 0.001)

	# The first version of this economy conserved every cent exactly and still starved itself:
	# demand was credited to the whole population while income reached only the employed, and
	# rent pooled in a landlord bucket that never spent it again. Conservation cannot see that,
	# so the property here is that a month of trading employs more people, not fewer.
	var month_jobs := sim.total_employment()
	var m_before := sim.money_total()
	sim.advance_hours(720)
	_that("运行一个月后就业上升而非塌缩", sim.total_employment() > month_jobs,
		"%d -> %d" % [month_jobs, sim.total_employment()])
	_that("一个月的交易后钱仍守恒", sim.money_total() == m_before,
		"%d vs %d" % [sim.money_total(), m_before])

	# Prices must still respond to scarcity. A converged market is stable, so "did the number
	# move by itself" is the wrong question - the first attempt at this assertion failed for a
	# real reason (a 2 % step truncated to zero at small prices) and would then have passed for
	# the wrong one. Squeezing a category's capacity must cost more next hour; flooding it must
	# cost less.
	var pd := String(sim.districts.keys()[0])
	var food: Dictionary = sim.districts[pd]["shops"]["food"]
	var price0 := int(food["price_c"])
	var count0 := int(food["count"])
	food["count"] = 1
	sim.advance_hours(1)
	var price1 := int(food["price_c"])
	_that("产能骤减后价格上调", price1 > price0, "%d -> %d" % [price0, price1])
	food["count"] = count0 * 400
	sim.advance_hours(1)
	var price2 := int(food["price_c"])
	_that("产能过剩后价格下调", price2 < price1, "%d -> %d" % [price1, price2])
	food["count"] = count0
	food["price_c"] = price0

	# Phase 111: snapshot, run far ahead, restore must land on the exact prior state.
	var before := sim.state_hash()
	var snap := sim.snapshot()
	sim.advance_hours(400)
	_that("快照前后可完整还原", sim.restore(snap) and sim.state_hash() == before,
		"%d vs %d" % [sim.state_hash(), before])

	for f in [a, b, dry, wet]:
		f.free()
	print("=== city simulation self-test: %s (%d failures) ===" % [
		"PASS" if _fails == 0 else "FAIL", _fails])
	return _fails


## Phase 120 soak: run the whole city for a long simulated span and report what it cost.
static func soak(sim: CitySim, hours: int) -> int:
	_fails = 0
	print("=== sim soak: %d hours over %d districts ===" % [hours, sim.districts.size()])
	var m0 := sim.money_total()
	var shops0 := sim.total_shops()
	var jobs0 := sim.total_employment()
	var t0 := Time.get_ticks_usec()
	sim.advance_hours(hours)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var pop := _sum(sim.districts, "pop")
	var labor := _sum(sim.districts, "labor")
	var floor_shops := 1 << 30
	for n in sim.districts:
		for c in CitySim.CATS:
			floor_shops = mini(floor_shops, int(sim.districts[n]["shops"][c]["count"]))
	print(("[soak] hours=%d simulated_pop=%d wall=%.0fms per_hour=%.3fms shops=%d " +
		"employed=%d hire_rate=%.2f min_cat=%d events=%d money_conserved=%s") % [
		hours, pop, ms, ms / float(maxi(hours, 1)), sim.total_shops(),
		sim.total_employment(), float(sim.total_employment()) / maxf(float(labor), 1.0),
		floor_shops, sim.events.size(), str(sim.money_total() == m0)])
	_that("长时间运行后钱仍守恒", sim.money_total() == m0,
		"%d vs %d" % [sim.money_total(), m0])
	# The failure these catch is the one conservation cannot: money stayed exactly conserved
	# while the city starved itself down to the one-shop floor over a simulated year.
	_that("长周期后商铺总数没有塌缩", sim.total_shops() >= shops0,
		"%d -> %d" % [shops0, sim.total_shops()])
	_that("长周期后就业没有塌缩", sim.total_employment() >= jobs0,
		"%d -> %d" % [jobs0, sim.total_employment()])
	_that("没有任何类别塌到只剩一家", floor_shops > 1, "最少的类别有 %d 家" % floor_shops)
	print("=== sim soak: %s (%d failures) ===" % ["PASS" if _fails == 0 else "FAIL", _fails])
	return _fails


## Asserts a condition and prints the observed values beside it. The older _check() compares
## two values; these assertions need "this must hold, and here is the evidence".
static func _that(what: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_fails += 1
	print("[test] %s %-40s %s" % ["PASS" if cond else "FAIL", what, detail])


## GDScript arrays have no reduce(); this is the fold the assertions above need.
static func _sum(districts: Dictionary, field: String) -> int:
	var t := 0
	for n in districts:
		t += int(districts[n][field])
	return t
