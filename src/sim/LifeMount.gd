class_name LifeMount
extends RefCounted
## One line of wiring, and the reason it is not inline: GameRoot is at the project's 900-line
## ceiling, and the living city needs a node created, named, added and bound to the ledger it
## subscribes to. Those four statements belong to a composition root, not to the economy itself.
##
## The order is load-bearing. `sim.bootstrap()` must have run, because the population pyramid is
## fitted to the census the ledger was built from - seeding it against an empty district table
## would produce a city of nobody, quietly.

static func mount(parent: Node, sim: CitySim, pop: PopulationSystem) -> CityLife:
	var life := CityLife.new()
	life.name = "CityLife"
	parent.add_child(life)
	life.attach(sim, pop)
	return life


## The live layer, found the same way the crowd and traffic systems find the economy: by group.
## A city with no life layer returns null, and the caller says so rather than simulating nothing
## and reporting a pass.
static func of(tree: SceneTree) -> CityLife:
	if tree == null:
		return null
	return tree.get_first_node_in_group("life") as CityLife
