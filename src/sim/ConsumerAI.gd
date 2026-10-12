class_name ConsumerAI
extends RefCounted
## Phase 244/250/251: a person's need becomes a shop's revenue.
##
## The economy already traded in aggregate: a district's households held a balance, a share of
## it went to each category every hour, and prices moved on the resulting utilisation. That is
## enough for a market and not enough for a city, because nothing a single NPC wanted had any
## consequence. Here one agent's hunger selects an actual storefront, pays actual cents out of
## the district's resident-cash bucket, and leaves a review that changes the next customer's
## choice. The purchase is booked as the shop's observed takings, so a lunch rush moves that
## category's price the following hour - which moves the next person's willingness to buy. That
## is Phase 244's "饥饿 -> 寻找餐厅 -> 消费 -> 经济变化" chain, executed.
##
## Where the money comes from, stated plainly: wages land in the district's household bucket,
## `credit_income` moves a slice of it into named residents' hands, and every purchase moves it
## from their hands into a shop. All four buckets are counted in `CitySim.money_total()`, so a
## person eating lunch cannot create or destroy one cent, and the existing conservation gate is
## what proves that rather than this comment.
##
## Choice is scored on the levers Phase 251 lists - income, age, interest, distance, rating,
## price - using the profile's own personality vector rather than a fresh roll, so two people on
## the same pavement walk into different shops for a stated reason.

const SITE_SCALE := 6.0

var ratings: Dictionary = {}			# site key -> {"sum": int, "n": int}
var spend_by: Dictionary = {}			# dn -> {cat: cents} since the last hour boundary
var buys_by: Dictionary = {}			# dn -> {cat: count}
var queue_at: Dictionary = {}			# site key -> count this hour
var purchases := 0
var revenue_c := 0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 0xC04A1


static func site_key(p: Vector2) -> int:
	return int(round(p.x / SITE_SCALE)) * 200000 + int(round(p.y / SITE_SCALE))


static func site_pos(k: int) -> Vector2:
	var gy := k % 200000
	var gx := int(k / 200000)
	return Vector2(float(gx) * SITE_SCALE, float(gy) * SITE_SCALE)


## A shop opens with a reputation, not with zero. Seeded from its own coordinates so the same
## storefront always starts at the same standing, and so the first customer is choosing between
## real differences instead of a field of identical zeros.
func rating_of(p: Vector2) -> Dictionary:
	var k := site_key(p)
	if not ratings.has(k):
		var q := GameGlobals.hash2(int(round(p.x / SITE_SCALE)), int(round(p.y / SITE_SCALE)), 913)
		ratings[k] = {"sum": int(round((2.6 + 2.2 * q) * 100.0)), "n": 40 + int(q * 60.0)}
	var r: Dictionary = ratings[k]
	return {"avg": float(int(r["sum"])) / 100.0 / maxf(float(int(r["n"])), 1.0), "n": int(r["n"])}


## How much of a price premium a given personality will still walk in the door for. Above this
## the person eats at home, and that refusal is what makes a district's price a real constraint
## on a shop's takings rather than a number everyone pays.
static func _tolerance(prof: NPCProfile) -> float:
	return 0.90 + 1.10 * prof.persona("spend") - 0.70 * prof.persona("rational")


## Phase 251's scoring, in one readable place. Everything is normalised so the coefficients mean
## the same thing in 陆家嘴 and in 普陀: price is compared against the wage-implied norm the
## market itself uses, distance against how far a person will actually walk.
##
## Note what this can and cannot decide. A district has one price per category, so price cannot
## pick a shop out of a row of them — it decides whether the person goes in at all. What selects
## the storefront is quality and walking distance, which is the honest shape of the model.
func choose(prof: NPCProfile, at: Vector2, cat: String, sim: CitySim,
		pop: PopulationSystem) -> Dictionary:
	var dn := sim.district_at(at)
	var d: Dictionary = sim.districts.get(dn, {})
	if d.is_empty() or pop.retail.is_empty():
		return {}
	var price_c := int(d["shops"][cat]["price_c"])
	var wage := maxf(float(int(d["wage_c"])), 1.0)
	var gap := float(price_c) * CitySim.PRICE_NORM / wage
	if gap > _tolerance(prof):
		return {}
	var richest := float(prof.personality.get("spend", 0.5))
	var prudent := float(prof.personality.get("rational", 0.5))
	var best: Dictionary = {}
	var best_score := -1e18
	for o in pop.sample_retail(at, 6):
		var p: Vector2 = o["p"]
		var dist := at.distance_to(p)
		var rt := rating_of(p)
		var score := float(rt["avg"]) * 1.6 - dist / 90.0 \
			- gap * (0.9 - 0.55 * richest + 0.5 * prudent) \
			+ 0.20 * log(1.0 + float(int(rt["n"])))
		if prof.occ == OccupationTable.Occ.STUDENT or prof.age < 19:
			score -= gap * 0.7
		if score > best_score:
			best_score = score
			best = {"p": p, "price_c": price_c, "cat": cat, "dist": dist,
				"rating": float(rt["avg"]), "dn": dn}
	return best


## Which need is loud enough to buy something about. Read against NPCProfile's own plan state so
## the two systems cannot disagree about what a person is currently doing.
static func _want(prof: NPCProfile) -> String:
	match prof.state:
		OccupationTable.State.LUNCH:
			return "food" if prof.food < 0.78 else ""
		OccupationTable.State.SHOP:
			return "retail" if prof.social > 0.35 else "leisure"
		OccupationTable.State.LEISURE:
			return "leisure" if prof.fun < 0.60 else ""
		_:
			return ""


## One purchase attempt for one agent, at most once per simulated hour. Returns {} when nothing
## was bought, which is the common case and not an error.
func maybe_buy(prof: NPCProfile, ag: Dictionary, sim: CitySim, pop: PopulationSystem,
		hidx: int) -> Dictionary:
	if prof.purse_c < 40 or prof.last_buy_hidx == hidx:
		return {}
	var cat := _want(prof)
	if cat.is_empty():
		return {}
	var p: Vector2 = ag["pos"]
	var pick := choose(prof, p, cat, sim, pop)
	if pick.is_empty():
		return {}
	var price := int(pick["price_c"])
	if prof.purse_c < price:
		return {}
	var paid := sim.resident_spend(String(pick["dn"]), cat, price)
	if paid <= 0:
		return {}
	prof.purse_c -= paid
	prof.last_buy_hidx = hidx
	prof.buys += 1
	prof.spent_c += paid
	_book(prof, ag, pick, cat, paid)
	return {"cat": cat, "paid": paid, "at": pick["p"], "rating": float(pick["rating"])}


## Books the transaction on the district's hour counters, the storefront's queue and its
## reputation. The shop's money itself moved inside `CitySim.resident_spend`.
func _book(prof: NPCProfile, ag: Dictionary, pick: Dictionary, cat: String, paid: int) -> void:
	purchases += 1
	revenue_c += paid
	var dn := String(pick["dn"])
	if not spend_by.has(dn):
		spend_by[dn] = {}
		buys_by[dn] = {}
	var sb: Dictionary = spend_by[dn]
	sb[cat] = int(sb.get(cat, 0)) + paid
	spend_by[dn] = sb
	var bb: Dictionary = buys_by[dn]
	bb[cat] = int(bb.get(cat, 0)) + 1
	buys_by[dn] = bb
	var k := site_key(pick["p"])
	queue_at[k] = int(queue_at.get(k, 0)) + 1
	ag["last_spend_c"] = paid
	## Review = what the shop delivered against what the price promised. A cheap, honest place
	## gains; an expensive disappointment loses, and that loss is what steers the next customer
	## away. This is the only loop here that outlives the single transaction.
	var gap := float(paid) * CitySim.PRICE_NORM / maxf(float(prof.income_hour_c), 1.0)
	var promise := 0.55 + 0.65 * gap
	var served := 0.86 + 0.34 * prof.mood + 0.20 * float(pick["rating"]) - 0.18 * (1.0 - prof.food)
	var delta := int(clampf((served - promise) * 2.2, -2.0, 2.0))
	var r: Dictionary = ratings[k]
	r["sum"] = int(r["sum"]) + delta * 100
	r["n"] = int(r["n"]) + 1
	ratings[k] = r
	prof.remember("shop_%s" % cat, 0.02 + 0.02 * float(delta))


## Hour boundary: the takings have already been credited to the shop as observed revenue, so
## this only rolls the per-hour reporting counters into history for the news wire.
func on_hour(sim: CitySim) -> void:
	spend_by.clear()
	buys_by.clear()
	queue_at.clear()


## Wages into hands for one named, working, tier-0 resident: one hour of the district wage, drawn
## from the same household bucket the market already pays wages into. This is a redistribution of a
## wage that exists, not a second payroll - `credit_wage` can only take what the bucket holds, and
## returns less when it cannot.
func credit_one(prof: NPCProfile, ag: Dictionary, sim: CitySim) -> int:
	if prof == null or not prof.has_job or int(ag.get("tier", 2)) != 0:
		return 0
	if prof.state != OccupationTable.State.WORK \
			and prof.state != OccupationTable.State.COMMUTE:
		return 0
	var p: Vector2 = ag["pos"]
	var dn := sim.district_at(p)
	var d: Dictionary = sim.districts.get(dn, {})
	if d.is_empty():
		return 0
	var got := sim.credit_wage(dn, int(d["wage_c"]))
	if got > 0:
		prof.purse_c += got
	return got


## The most-crowded counter this hour, for the HUD and for a news line about a queue.
func longest_queue() -> Dictionary:
	var busiest := 0
	var bk := 0
	for k in queue_at.keys():
		if int(queue_at[k]) > busiest:
			busiest = int(queue_at[k])
			bk = int(k)
	return {"n": busiest, "at": site_pos(bk) if busiest > 0 else Vector2.ZERO}


func stats() -> Dictionary:
	var q := longest_queue()
	return {"purchases": purchases, "revenue_c": revenue_c, "rated": ratings.size(),
		"queue": int(q["n"])}
