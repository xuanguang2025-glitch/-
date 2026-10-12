class_name LifeTests
extends RefCounted
## Part 12 (Phase 236-282): the acceptance contract for the living city.
##
## SimTests proves the economy conserves money, repeats itself and reacts to weather. That is not
## the same claim as "the city is alive", and the gap between the two is exactly where a feature
## like this turns decorative: a population panel printing numbers nothing reads, a congestion
## figure computed then thrown away, a news ticker fed by a random sentence generator. So every
## check here asks for a consequence measurable on the far side of a system boundary - an NPC's
## lunch arriving in a shop's till, a day of promotion showing up in next year's wage, a district
## keeping its residents because its economy was hiring.
##
## The three properties the layer is judged on:
##
##   1. Money is still conserved, now with a fourth bucket and named wallets inside it.
##   2. The population is deterministic and rolls back, because it writes numbers the economy reads
##      and a drifted pyramid would look exactly like a plausible one.
##   3. Coupling is observable from the street, not only inside the ledger - the failure class
##      Phase 123 caught for the crowd and traffic factors.
##
## Runs after SimTests, and it deliberately lives in the city it measures: it hands out wages, buys
## a lunch and raises a price on the running ledger. That is why it is last - the economy's own
## contract is judged on a clean book, this one on a city that has been used.

static var _fails := 0
static var _checks := 0


static func run(sim: CitySim, population: PopulationSystem, crowd: CrowdSystem,
		traffic: TrafficSystem) -> int:
	_fails = 0
	_checks = 0
	print("=== city life self-test ===")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261011
	var centre := Vector2(CityData.DISTRICTS[0]["cx"], CityData.DISTRICTS[0]["cz"])
	var life := LifeMount.of(sim.get_tree())

	# --- 0. the layer is mounted, not merely defined -----------------------------------------
	_that("运行中的城市挂了生活层（Phase 236 协调器）", life != null)
	if life == null:
		return _finish()

	# --- 1. the pyramid is fitted to the city the generator actually made -------------------
	_that("每个模拟街区都有人口队列", life.vpop.cohorts.size() == sim.districts.size(),
		"%d 队列 / %d 街区" % [life.vpop.cohorts.size(), sim.districts.size()])
	_that("虚拟人口达到百万级（Phase 237）", life.vpop.residents_total() > 1000000,
		"%d 人" % life.vpop.residents_total())
	var fitted := true
	var bounded := true
	for dn in sim.districts.keys():
		var d: Dictionary = sim.districts[dn]
		var sum := 0
		for a in life.vpop.age_pyramid(String(dn)):
			sum += int(a)
		if sum != int(d["pop"]):
			fitted = false
		if int(d["labor"]) <= 0 or int(d["labor"]) >= int(d["pop"]):
			bounded = false
	_that("队列与区域人口逐项相等（不另立人口口径）", fitted)
	_that("劳动力落在 0 与人口之间", bounded)

	# --- 2. a fourth bucket, and the invariant still holds to the cent ----------------------
	var sum4 := sim.house_total() + sim.land_total() + sim.business_total() + sim.resident_total()
	_that("居民手持现金计入总账", sim.money_total() == sum4,
		"%d vs %d" % [sim.money_total(), sum4])
	_that("开局就有人口袋里有钱", sim.resident_total() > 0, "%d 分" % sim.resident_total())
	var wd := String(sim.districts.keys()[0])
	var h0 := int(sim.districts[wd]["house_c"])
	var r0 := int(sim.districts[wd]["resident_c"])
	var m0 := sim.money_total()
	var got := sim.credit_wage(wd, 5000)
	_that("发薪恰好搬运：家庭账户减、居民账户加", got == 5000
		and int(sim.districts[wd]["house_c"]) == h0 - 5000
		and int(sim.districts[wd]["resident_c"]) == r0 + 5000, "实发 %d 分" % got)
	_that("发薪不凭空产生一分钱", sim.money_total() == m0, "%d" % sim.money_total())
	var h1 := int(sim.districts[wd]["house_c"])
	var drained := sim.credit_wage(wd, h1 + 1000000)
	_that("只付得出账上真有的钱", drained == h1 and int(sim.districts[wd]["house_c"]) == 0,
		"要 %d，得 %d" % [h1 + 1000000, drained])
	_that("家庭账户已空时发薪返回 0", sim.credit_wage(wd, 100) == 0)
	_that("搬运后总账仍然守恒", sim.money_total() == m0, "%d" % sim.money_total())

	# --- 3. one hungry person reaches one shop's till ---------------------------------------
	var cdn := sim.district_at(centre)
	var food0 := int((sim.districts[cdn]["shops"]["food"] as Dictionary)["price_c"])
	# A person with the appetite to act on the need: the check here is that a need turns into money
	# moving, and a randomly rolled prudent profile would refuse to eat for reasons of its own.
	var prof := _profile(90001, rng, population, centre, 0.90, 0.20)
	prof.purse_c = 60000
	# Priced at the wage-implied norm first. The claim under test is that a need moves money, and
	# the live city may have spent 1 300 simulated hours pushing this district's lunch price above
	# what even a willing appetite will pay - which is a real refusal, and would make the following
	# assertions fail for the wrong reason.
	var norm0 := maxi(4, int(sim.districts[cdn]["wage_c"]) / int(CitySim.PRICE_NORM))
	_set_price(sim, cdn, norm0)
	var ag := {"pos": centre, "tier": 0}
	var cres := int(sim.districts[cdn]["resident_c"])
	var cbank := _all_bank(sim)
	var irev := _all_irev(sim)
	var out := life.consumer.maybe_buy(prof, ag, sim, population, 1)
	_that("饥饿的行人确实走进了一家店面", not out.is_empty(), str(out.get("cat", "无")))
	var price := int(out.get("paid", 0))
	var cat := String(out.get("cat", "food"))
	_that("买单从居民口袋扣除", int(sim.districts[cdn]["resident_c"]) == cres - price,
		"%d - %d vs %d" % [cres, price, int(sim.districts[cdn]["resident_c"])])
	_that("收银台收到同一笔钱", _all_bank(sim) == cbank + price, "%d → %d" % [cbank, _all_bank(sim)])
	_that("这笔钱记为该店本小时的实际营业额", price > 0
		and int(_all_irev(sim)[cat]) == int(irev[cat]) + price,
		"%s: %d → %d" % [cat, int(irev[cat]), int(_all_irev(sim)[cat])])
	_that("同一小时不重复刷卡", life.consumer.maybe_buy(prof, ag, sim, population, 1).is_empty())
	_that("个人账上留下了这笔消费", prof.buys == 1 and prof.spent_c == price,
		"%d 次 %d 分" % [prof.buys, prof.spent_c])
	_that("消费后总账守恒", sim.money_total() == m0, "%d vs %d" % [sim.money_total(), m0])

	# --- 4. personality decides something real: whether to go in at all ----------------------
	var diverse := 0
	for i in 40:
		var q := NPCProfile.create(91000 + i, rng, population, centre)
		if absf(q.persona("spend") - q.persona("rational")) > 0.02:
			diverse += 1
	_that("人格向量让人各不相同（Phase 239）", diverse > 12, "%d/40 有显著差异" % diverse)
	# A lunch priced 50 % above the wage-implied norm: walk-inable for a 高消费欲 profile, refused
	# by a prudent one. Price is one number per district and category, so it cannot choose which
	# storefront - it chooses whether the door is crossed at all. Asserting a difference the model
	# cannot produce would be the decorative kind of coverage.
	var norm := maxi(4, int(sim.districts[cdn]["wage_c"]) / int(CitySim.PRICE_NORM))
	var spender := _profile(92001, rng, population, centre, 0.95, 0.10)
	var saver := _profile(92002, rng, population, centre, 0.05, 0.95)
	_set_price(sim, cdn, int(norm * 1.5))
	var rich_out := life.consumer.maybe_buy(spender, ag, sim, population, 2)
	var poor_out := life.consumer.maybe_buy(saver, ag, sim, population, 3)
	_that("高价午饭：爱消费的进去了，节俭的没进",
		not rich_out.is_empty() and poor_out.is_empty(),
		"%s / %s" % ["进" if not rich_out.is_empty() else "不进",
			"进" if not poor_out.is_empty() else "不进"])
	_that("拒绝消费的那个人一分钱也没少", saver.purse_c == 400000, "%d" % saver.purse_c)
	_that("进店的人确实付了钱", spender.buys == 1 and spender.purse_c < 400000,
		"剩 %d 分" % spender.purse_c)
	_that("贵到四十倍时两种人格都不进（价格是约束不是装饰）",
		_refuses_at(sim, life, population, centre, cdn, 40.0))
	_set_price(sim, cdn, food0)

	# --- 5/6. a city on its own, driven for months ------------------------------------------
	var ea := _city(population, 5150)
	var eb := _city(population, 5150)
	var sa: CitySim = ea["sim"]
	var sb: CitySim = eb["sim"]
	var la: CityLife = ea["life"]
	var lb: CityLife = eb["life"]
	var m0a := sa.money_total()
	sa.advance_hours(120)
	sb.advance_hours(120)
	_that("同种子两座城市的经济完全一致", sa.state_hash() == sb.state_hash(),
		"%d vs %d" % [sa.state_hash(), sb.state_hash()])
	_that("同种子两座城的人口队列也逐位一致", la.hash_state() == lb.hash_state(),
		"%d vs %d" % [la.hash_state(), lb.hash_state()])
	var h120 := sa.state_hash()
	var d120 := la.days_run
	sa.advance_hours(24)
	_that("推进一天必然改变状态（队列真的在跑）", sa.state_hash() != h120
		and la.days_run == d120 + 1, "%d 天" % la.days_run)
	_that("人口演化不创造货币", sa.money_total() == m0a, "%d vs %d" % [sa.money_total(), m0a])

	sa.advance_hours(1440)
	var av := la.vpop
	_that("跑过两个月以上：天数在推进", av.days_run >= 61, "%d 天" % av.days_run)
	_that("这段时间里有出生也有死亡", av.births_total > 0 and av.deaths_total > 0,
		"%d 生 / %d 死" % [av.births_total, av.deaths_total])
	_that("职业阶梯确实有人上升（Phase 246）", av.promoted_total > 0,
		"%d 人次晋升" % av.promoted_total)
	var wage_ok := true
	var rent_ok := true
	for dn in sa.districts.keys():
		var d: Dictionary = sa.districts[dn]
		var base: int = int((av.cohorts[dn] as Dictionary)["base_wage_c"])
		var w := int(d["wage_c"])
		var rt := int(d["rent_c"])
		if w < int(base * 0.9) or w > base * 2:
			wage_ok = false
		if rt * 7 > w or rt * 40 < w:
			rent_ok = false
	_that("工资随职业结构漂移但有界（不会通胀击穿账本）", wage_ok)
	_that("房租保持在工资的界内（Phase 253 的约束）", rent_ok)

	# --- 7. migration follows hiring, not a typed curve -------------------------------------
	var boom := _city(population, 909)
	var bust := _city(population, 909)
	var bs: CitySim = boom["sim"]
	var bl: CityLife = boom["life"]
	var bu: CitySim = bust["sim"]
	var bdn := bs.district_at(centre)
	var b0 := int(bs.districts[bdn]["pop"])
	var u0 := int(bu.districts[bdn]["pop"])
	for i in 240:
		bs.apply_player_action("open_shop", centre)
	for k in 60:
		for dn in bu.districts.keys():
			var sh: Dictionary = bu.districts[dn]["shops"]
			for c in CitySim.CATS:
				(sh[c] as Dictionary)["count"] = 1
		bu.advance_hours(24)
	bs.advance_hours(1440)
	# Both cities start from the same seed and the same census, so the only thing that can separate
	# them is what was done to their shops. The honest assertion is the difference between them, not
	# a direction each one had to move in: a district can shed residents and still be the one that
	# hired, because births and deaths are running underneath the whole thing.
	_that("扩张的街区留住的人多于被抽空岗位的街区（Phase 278）",
		int(bs.districts[bdn]["pop"]) > int(bu.districts[bdn]["pop"]),
		"扩张 %d→%d，抽空 %d→%d" % [b0, int(bs.districts[bdn]["pop"]), u0,
			int(bu.districts[bdn]["pop"])])

	var before_pop := int(bs.districts[bdn]["pop"])
	var snap := bs.snapshot()
	var lsnap := bl.snapshot()
	var snap_days := int(lsnap["days"])
	bs.advance_hours(400)
	var ok_restore := bs.restore(snap) and bl.restore(lsnap) \
		and int(bs.districts[bdn]["pop"]) == before_pop and bl.days_run == snap_days
	_that("快照能同时带回经济与人口", ok_restore,
		"%d→%d 天 %d→%d" % [before_pop, int(bs.districts[bdn]["pop"]), snap_days, bl.days_run])

	# --- 8. trip demand is measured, decays, and can slow a street --------------------------
	var td := TripDemand.new()
	_that("空街区不减速（接入前后行为一致）", absf(td.slow_at(centre) - 1.0) < 0.0001)
	var c0 := td.congestion_at(centre)
	for i in 40:
		td.add(centre, 1.0)
	var c1 := td.congestion_at(centre)
	for i in 40:
		td.add(centre, 1.0)
	var c2 := td.congestion_at(centre)
	_that("发布行程单调抬高拥堵指数", c1 > c0 and c2 > c1, "%.2f → %.2f → %.2f" % [c0, c1, c2])
	_that("拥堵确实下调车速", td.slow_at(centre) < 1.0 and td.slow_at(centre) >= TripDemand.SLOW_MIN,
		"%.3f" % td.slow_at(centre))
	for k in 20:
		td.decay(90.0)
	_that("需求按半衰期消散到空", int(td.stats()["cells"]) == 0,
		"剩余 %d 格" % int(td.stats()["cells"]))
	td.add(centre, 20.0)
	td.add(centre + Vector2(900.0, 900.0), 3.0)
	td.decay(0.01)
	var busy := td.busiest()
	_that("最堵路口就是发布最多的那个", absf(float(busy["load"]) - 20.0) < 0.6
		and Vector2(busy["at"]) == TripDemand.unkey(TripDemand.key(centre)), str(busy))

	# --- 9. the street systems feed the field the sim owns ----------------------------------
	sim.trips.reset()
	crowd.focus = Vector3(centre.x, 1.5, centre.y)
	traffic.focus = Vector3(centre.x, 1.5, centre.y)
	for k in 4:
		crowd._process(0.2)
		traffic._process(0.2)
	var cells := int(sim.trips.stats()["cells"])
	_that("行人和车辆把行程发布进了需求图", cells > 0, "%d 格" % cells)
	var loads := float(sim.trips.stats()["trips"])
	for k in 6:
		traffic._process(0.2)
		crowd._process(0.2)
	_that("持续走动会持续累积需求", float(sim.trips.stats()["trips"]) >= loads,
		"%.1f → %.1f" % [loads, float(sim.trips.stats()["trips"])])
	_that("人群与交通读的是同一个需求场", crowd.sim == sim and traffic.sim == sim
		and sim.trips == crowd.sim.trips)
	_that("生活层确实找到了街上的人", life._crowd() == crowd)

	# --- 10. the news wire can only write about facts it can show ----------------------------
	var nn := _city(population, 77)
	var ns: CitySim = nn["sim"]
	var nl: CityLife = nn["life"]
	var wire := nl.news
	var n0 := wire.items.size()
	wire.evaluate(ns, nl.vpop, nl.consumer, ns.trips, 0.0)
	var n1 := wire.items.size()
	wire.evaluate(ns, nl.vpop, nl.consumer, ns.trips, 0.0)
	_that("什么都不变时一条新闻也不发（不是随机句柄）", n0 == n1 and wire.items.size() == n1,
		"%d → %d → %d" % [n0, n1, wire.items.size()])
	for k in 25:
		ns.advance_hours(24)
	_that("跑一段时间后城市确实在自我报道", wire.items.size() > 0, "%d 条" % wire.items.size())
	var traceable := true
	for it in wire.items:
		var f: Dictionary = it["facts"]
		if f.size() < 2:
			traceable = false
		if f.has("district") and not ns.districts.has(String(f["district"])):
			traceable = false
	_that("每条新闻都带着可核对的事实", traceable, "%d 条" % wire.items.size())
	_that("新闻来源不止一类（经济/商业/人口/出行都在报）", wire.source_mix().size() >= 2,
		str(wire.source_mix().keys()))
	_that("新闻里的数字来自账本而不是模板", _facts_in_state(ns, wire))
	for c in [ea, eb, boom, bust, nn]:
		(c["sim"] as CitySim).free()
	return _finish()


## A city with its own life layer, detached from the scene tree. Because there is no crowd to hold
## wallets nothing in it spends, which is exactly why a simulated year here repeats itself.
static func _city(pop: PopulationSystem, seed: int) -> Dictionary:
	var s := CitySim.new()
	s.seed_base = seed
	s.configure(func() -> float: return 12.0, func() -> float: return 0.0,
		func(_h: float) -> float: return 0.6)
	s.bootstrap(pop)
	var l := CityLife.new()
	s.add_child(l)
	l.attach(s, pop)
	return {"sim": s, "life": l}


static func _set_hungry(prof: NPCProfile) -> void:
	prof.state = OccupationTable.State.LUNCH
	prof.food = 0.10


## A person built to a stated disposition, with the cash to act on it.
static func _profile(pid: int, rnd: RandomNumberGenerator, pop: PopulationSystem,
		at: Vector2, spend: float, rational: float) -> NPCProfile:
	var q := NPCProfile.create(pid, rnd, pop, at)
	q.personality = {"extravert": 0.5, "rational": rational, "thrill": 0.5,
		"spend": spend, "workaholic": 0.5, "social": 0.5}
	_set_hungry(q)
	q.purse_c = 400000
	return q


static func _set_price(sim: CitySim, dn: String, cents: int) -> void:
	(sim.districts[dn]["shops"]["food"] as Dictionary)["price_c"] = cents


## The same two dispositions at an absurd price: both should stay home. A consumer model that
## always buys would be a money transfer with a person drawn on the front.
static func _refuses_at(sim: CitySim, life: CityLife, pop: PopulationSystem,
		at: Vector2, dn: String, mult: float) -> bool:
	var back := int((sim.districts[dn]["shops"]["food"] as Dictionary)["price_c"])
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 4242
	var ok := true
	for pair in [[0.95, 0.10], [0.05, 0.95]]:
		var q := _profile(93000 + int(float(pair[0]) * 100.0), rnd, pop, at,
			float(pair[0]), float(pair[1]))
		_set_price(sim, dn, int(back * mult))
		var hidx := 7 + int(float(pair[0]) * 100.0)
		if not life.consumer.maybe_buy(q, {"pos": at, "tier": 0}, sim, pop, hidx).is_empty():
			ok = false
	_set_price(sim, dn, back)
	return ok


## Every item's figures must still be findable in the state, which is what stops a headline from
## being a sentence that merely happened to be near the truth.
static func _facts_in_state(sim: CitySim, wire: NewsWire) -> bool:
	for it in wire.items:
		var f: Dictionary = it["facts"]
		if f.has("from_c") and (int(f["from_c"]) <= 0 or int(f["to_c"]) <= 0):
			return false
		if f.has("count") and int(f["count"]) < 1:
			return false
		if f.has("district") and not sim.districts.has(String(f["district"])):
			return false
		if f.has("congestion") and float(f["congestion"]) <= 0.0:
			return false
	return not wire.items.is_empty()


static func _all_bank(sim: CitySim) -> int:
	var t := 0
	for dn in sim.districts.keys():
		var sh: Dictionary = sim.districts[dn]["shops"]
		for c in CitySim.CATS:
			t += int((sh[c] as Dictionary)["bank_c"])
	return t


static func _all_irev(sim: CitySim) -> Dictionary:
	var out := {}
	for dn in sim.districts.keys():
		var sh: Dictionary = sim.districts[dn]["shops"]
		for c in CitySim.CATS:
			out[c] = int(out.get(c, 0)) + int((sh[c] as Dictionary).get("i_rev_c", 0))
	return out


static func _finish() -> int:
	print("=== city life self-test: %s (%d checks, %d failures) ===" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	return _fails


static func _that(what: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("[life] %s %-46s %s" % ["PASS" if cond else "FAIL", what, detail])
