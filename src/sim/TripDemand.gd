class_name TripDemand
extends RefCounted
## Phase 256: 出行需求图. Every pedestrian and every car publishes the trip it is currently
## making into a coarse grid, so "how badly is this corner wanted right now" is a measured
## quantity rather than a curve someone typed in.
##
## Phase 257 turns that measurement into 拥堵: demand over the free-flow capacity of a cell is
## a congestion index, and the index is what slows cars and walkers down. That makes rush hour
## a consequence of schedules (Part 12's home -> work -> leisure chain) instead of a clock
## lookup — if the NPC plans change, the street gets slower or faster with them.
##
## Deliberately not part of CitySim's determinism contract: this field is written by live
## agents on live frame timings, so it is reproducible in shape, not bit for bit. It is kept
## out of `state_hash()` for exactly that reason, and tested as a pure object instead.

const CELL := 110.0
## Weighted bodies one intersection cell carries before it stops being free flow. A 110 m square
## holds a couple of hundred people on its pavements and a few dozen cars on its carriageway; past
## that the corner is queued. This number is a capacity, not a tuning knob for how slow the game
## should feel - the first version was calibrated against the agent budget and read 8638 at rush
## hour, because the field was accumulating per frame rather than per second.
const CAP_PER_CELL := 150.0
const SLOW_MIN := 0.42
## Half-life of a published trip, in seconds of wall clock. Long enough that a crowd crossing an
## intersection registers, short enough that an empty street empties within a few seconds.
const HALFLIFE := 90.0
## How long one published unit stays counted on average. Dividing a publication by it makes the
## field settle at the weighted number of bodies present, instead of an integral that grows for as
## long as the player stands there and at whatever framerate they happen to be getting.
const RETENTION := HALFLIFE / log(2.0)

var _load: Dictionary = {}		# packed cell -> float trip-units
var _peak := 0.0
var _sum := 0.0
var _cells := 0
var _busiest_k := 0
## The summary is folded from the grid on demand, not on every write: 320 agents publish per frame
## and only the HUD, the news wire and the tests ever ask what the peak was.
var _dirty := true


static func key(p: Vector2) -> int:
	var ix := int(floor(p.x / CELL))
	var iy := int(floor(p.y / CELL))
	return (ix + 4096) * 8192 + (iy + 4096)


static func unkey(k: int) -> Vector2:
	var iy := k % 8192 - 4096
	var ix := int(k / 8192) - 4096
	return Vector2((float(ix) + 0.5) * CELL, (float(iy) + 0.5) * CELL)


## `w` is the trip's weight: a car contributes more than a walker because a car occupies the
## carriageway, and a car at 40 km/h needs more than twice the road a pedestrian does.
func add(p: Vector2, w: float) -> void:
	var k := key(p)
	_load[k] = float(_load.get(k, 0.0)) + w
	_dirty = true


## Publishes one agent's presence for one frame. Dividing by the retention time makes the field
## settle at the weighted number of bodies actually standing or sitting in the cell: an agent that
## stays contributes exactly `units`, one that passes through contributes a fraction of it. Without
## the divide the quantity accumulated per frame, so the index scaled with framerate and with how
## long the player lingered - it read 8638 on a busy 黄浦 corner and pinned every street to the
## slowdown floor, which the HUD caught before any test did.
func publish(p: Vector2, units: float, delta: float) -> void:
	add(p, units * delta / RETENTION)


func decay(dt: float) -> void:
	if dt <= 0.0:
		return
	var f := exp(-log(2.0) * dt / HALFLIFE)
	for k in _load.keys():
		var v := float(_load[k]) * f
		if v < 0.01:
			_load.erase(k)
		else:
			_load[k] = v
	## A decay is itself a change to the grid, and the summary must follow it: the writers set the
	## dirty flag, but once nothing is left to write, a flag that is already clear would leave the
	## peak reporting a crowd that has gone home.
	_dirty = true
	_rebuild()


## Recomputed on demand rather than on every write: the writers run every frame for every agent,
## and a field that reports a stale peak until someone decays it is a field the HUD can lie with.
func _rebuild() -> void:
	if not _dirty:
		return
	_peak = 0.0
	_sum = 0.0
	_cells = _load.size()
	_busiest_k = 0
	for k in _load.keys():
		var v := float(_load[k])
		_sum += v
		if v > _peak:
			_peak = v
			_busiest_k = int(k)
	_dirty = false


func load_at(p: Vector2) -> float:
	return float(_load.get(key(p), 0.0))


## 0 = nothing wanted here, 1 = exactly free flow, above 1 = more trips than the street holds.
func congestion_at(p: Vector2) -> float:
	return load_at(p) / CAP_PER_CELL


## The only number the street systems need. Normalised so an unobserved corner behaves exactly
## as it did before this file existed — a multiplier that is 1.0 at zero demand is what lets the
## performance and "rain buys rides" assertions stay meaningful.
func slow_at(p: Vector2) -> float:
	var c := congestion_at(p)
	return clampf(1.0 / (1.0 + 0.75 * c * c), SLOW_MIN, 1.0)


## City-wide index for the HUD and the news wire: peak cell over capacity.
func peak_congestion() -> float:
	_rebuild()
	return _peak / CAP_PER_CELL


func busiest() -> Dictionary:
	_rebuild()
	if _cells == 0:
		return {}
	return {"at": unkey(_busiest_k), "load": _peak, "congestion": _peak / CAP_PER_CELL}


func stats() -> Dictionary:
	_rebuild()
	return {"cells": _cells, "peak": _peak, "index": _peak / CAP_PER_CELL,
		"trips": _sum, "mean": (_sum / float(_cells)) if _cells > 0 else 0.0}


func reset() -> void:
	_load.clear()
	_dirty = true
	_rebuild()
