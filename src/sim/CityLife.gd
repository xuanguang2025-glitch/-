class_name CityLife
extends Node
## Phase 236: USOWCityLifeSubsystem, in Godot. The single place where the city's living layers
## meet, because the alternative — population, consumption and news each reaching into each other
## — is three systems holding three private opinions about the same resident.
##
## It owns:
##
##   VirtualPopulation  aging, birth, death, promotion, migration   (Phase 237-240/246/247/278)
##   ConsumerAI         a need turning into a purchase and a review  (Phase 244/250/251)
##   NewsWire           what the city just did, reported back         (Phase 266/267)
##
## and reads `sim.trips`, which CitySim owns because the crowd and the traffic system already
## resolve the sim by group and publish into it every frame (Phase 256/257).
##
## Why it subscribes to the ledger instead of being owned by it. CitySim used to create this node
## and hold it, and the project would not compile: CityLife -> CitySim -> CityLife is a class-name
## cycle, and GDScript resolves global classes at parse time, not at call time, so every script
## that touched either one failed with "Could not find type CityLife". The edge was cut on the
## ledger's side, which is the right place to cut it — the economy must not know who is reading it.
## CitySim publishes `ticked`; this node listens. LifeMount does the one line of wiring.
##
## The same rule keeps this node from holding a typed CrowdSystem: the crowd reads the congestion
## this node publishes, so a typed field back would close the cycle again. Agents are therefore
## fetched by group and treated as arrays. That is a deliberate loss of typing, and it is the only
## place in the living layer where typing is given up.
##
## Ordering inside an hour is the money's ordering: wages arrive before anyone can spend them,
## purchases are booked before the hour's counters roll over, and the news desk reads last so it
## reports what happened instead of what is about to.

var sim: CitySim
var population: PopulationSystem
var vpop := VirtualPopulation.new()
var consumer := ConsumerAI.new()
var news := NewsWire.new()

var hours_seen := 0
var days_run := 0
var wages_credited_c := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group("life")
	_rng.seed = 0xC17A7E
	set_process(true)


## The trip field decays in wall clock, not in simulated hours: it measures the crowd that is
## standing there now. A day of game time is about eight minutes of real time, and a crush that
## never cleared would be a statistic about the session rather than about the intersection.
func _process(delta: float) -> void:
	if sim != null:
		sim.trips.decay(delta)


## Binds to an already-bootstrapped economy, and turns the census into a population. Called by
## LifeMount in the running game and directly by the tests, which is how a detached CitySim can be
## given a year of demographic history.
func attach(s: CitySim, pop: PopulationSystem) -> void:
	sim = s
	population = pop
	## Seeded here rather than in `_ready`: a city built by a test is never in the tree, and a life
	## layer whose demographic dice came from the platform default would make two identical
	## simulations disagree. That was not hypothetical - the determinism gate caught exactly this.
	_rng.seed = 0xC17A7E
	vpop.seed_from(sim, pop)
	if not sim.ticked.is_connected(on_tick):
		sim.ticked.connect(on_tick)


func on_tick() -> void:
	on_hour(sim.wet_factor())


func on_hour(rain: float) -> void:
	hours_seen += 1
	if sim == null:
		return
	if hours_seen % 24 == 0:
		days_run += 1
		vpop.advance_day(sim, _rng)
	_settle_individuals()
	news.evaluate(sim, vpop, consumer, sim.trips, rain)
	_publish_readout(rain)


## The money half, with its honest limit: wallets belong to agents, and agents exist only where a
## crowd is being stepped. A city simulated with no street still ages, promotes, prices its lunches
## and prints its news, but nobody buys lunch in it. That is asserted, not assumed.
func _settle_individuals() -> void:
	if population == null and get_tree() != null:
		population = get_tree().get_first_node_in_group("population") as PopulationSystem
	var crowd := _crowd()
	if crowd == null or population == null:
		return
	var lists: Array = [crowd.get("agents"), crowd.get("pinned")]
	for li in 2:
		var list: Array = lists[li]
		for ag in list:
			var prof: NPCProfile = ag.get("prof")
			if prof == null:
				continue
			if int(ag.get("tier", 2)) == 0 and li == 0:
				wages_credited_c += consumer.credit_one(prof, ag, sim)
			consumer.maybe_buy(prof, ag, sim, population, sim.hours_run)
	consumer.on_hour(sim)


func _crowd() -> Node:
	if get_tree() == null:
		return null
	return get_tree().get_first_node_in_group("crowd")


## What the player sees without opening anything. Deliberately the same numbers the acceptance
## contract asserts on, so a live readout cannot coexist with a broken system behind it.
func _publish_readout(rain: float) -> void:
	GameGlobals.life = {"days": days_run, "residents": vpop.residents_total(),
		"births": vpop.births_total, "deaths": vpop.deaths_total,
		"migrated": vpop.migrated_total, "promoted": vpop.promoted_total,
		"congestion": sim.trips.peak_congestion(), "purchases": consumer.purchases,
		"revenue_c": consumer.revenue_c, "wages_c": wages_credited_c,
		"rain": rain, "head": news.latest(), "cohorts": vpop.cohorts.size()}


func headline() -> String:
	return news.latest()


func stats() -> Dictionary:
	return GameGlobals.life.duplicate()


func snapshot() -> Dictionary:
	return {"version": 1, "hours_seen": hours_seen, "days": days_run,
		"wages_c": wages_credited_c, "purchases": consumer.purchases,
		"revenue_c": consumer.revenue_c, "vpop": vpop.snapshot()}


func restore(s: Dictionary) -> bool:
	if typeof(s) != TYPE_DICTIONARY or not s.has("vpop"):
		return false
	hours_seen = int(s.get("hours_seen", 0))
	days_run = int(s.get("days", 0))
	wages_credited_c = int(s.get("wages_c", 0))
	consumer.purchases = int(s.get("purchases", 0))
	consumer.revenue_c = int(s.get("revenue_c", 0))
	return vpop.restore(s["vpop"])


func hash_state() -> int:
	return vpop.hash_state()
