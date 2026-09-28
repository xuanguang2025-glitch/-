class_name ChunkCtx
extends RefCounted
## Output bag for one chunk build pass. Kept as plain data so the builder, the streamer
## and the collision pass can all read it without owning nodes.

var buildings: MeshFusion = MeshFusion.new()
var plates: MeshFusion = MeshFusion.new()
var streets: MeshFusion = MeshFusion.new()
var props: MeshFusion = MeshFusion.new()
var emissive: MeshFusion = MeshFusion.new()
var colliders: Array = []			# {c: Vector3 centre, s: Vector3 size, r: float yaw}
var water_bed: Array = []			# quads that need the bed material
var spawn_points: Array = []		# Vector2 walkable spots for NPC seeding
var drive_points: Array = []		# {p: Vector2, dir: Vector2, w: float} street lanes
var cell_count: int = 0
var tri_total: int = 0
var detail: bool = true			# false on distant LOD passes: skip clutter

## Ground colour slots, one per STEP-sized cell of the chunk's terrain grid. Blocks paint
## their own slot as they are generated, so a shared point can never be classified two ways
## by two chunks, and the ground pass never has to ask which block contains a sample.
const UNPAINTED := Color(0, 0, 0, -1)
var ground_min := Vector2.ZERO
var ground_step := 25.0
var ground_n := 0
var ground_cols: Array = []

var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func begin_ground(min_p: Vector2, n: int, step: float) -> void:
	ground_min = min_p
	ground_step = step
	ground_n = n
	ground_cols.resize(n * n)
	ground_cols.fill(UNPAINTED)
	occupied.resize(n * n)
	occupied.fill(0)


## Slots covered by a building this chunk actually emitted. Kept alongside the colour grid
## so "can something be built here" is answerable without a spatial index of every tower.
var occupied: PackedByteArray


## Fill the slots whose sample point falls inside this block's plot polygon.
func paint_plate(quad: PackedVector2Array, col: Color) -> void:
	if ground_n == 0:
		return
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p in quad:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	var i0 := clampi(int((lo.x - ground_min.x) / ground_step), 0, ground_n - 1)
	var i1 := clampi(int((hi.x - ground_min.x) / ground_step), 0, ground_n - 1)
	var j0 := clampi(int((lo.y - ground_min.y) / ground_step), 0, ground_n - 1)
	var j1 := clampi(int((hi.y - ground_min.y) / ground_step), 0, ground_n - 1)
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			var c := ground_min + Vector2(float(i) + 0.5, float(j) + 0.5) * ground_step
			if Lattice.quad_has(quad, c):
				ground_cols[j * ground_n + i] = col


## Mark the footprint a building will cover. Inset because generators pull towers in from
## the plot edge, and a placement is allowed on the strip between building and street.
func mark_occupied(quad: PackedVector2Array, inset_m: float) -> void:
	if ground_n == 0:
		return
	var q := quad
	if inset_m > 0.0:
		q = CellProgram.inset(quad, inset_m)
	if q.size() < 3:
		return
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p in q:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	var i0 := clampi(int((lo.x - ground_min.x) / ground_step), 0, ground_n - 1)
	var i1 := clampi(int((hi.x - ground_min.x) / ground_step), 0, ground_n - 1)
	var j0 := clampi(int((lo.y - ground_min.y) / ground_step), 0, ground_n - 1)
	var j1 := clampi(int((hi.y - ground_min.y) / ground_step), 0, ground_n - 1)
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			var c := ground_min + Vector2(float(i) + 0.5, float(j) + 0.5) * ground_step
			if Lattice.quad_has(q, c):
				occupied[j * ground_n + i] = 1


func setup(seed: int) -> void:
	rng.seed = seed
	buildings.clear()
	plates.clear()
	streets.clear()
	props.clear()
	emissive.clear()
	colliders.clear()
	water_bed.clear()
	spawn_points.clear()
	drive_points.clear()
	cell_count = 0
	tri_total = 0
	ground_cols.resize(0)
	ground_n = 0


func add_box_collider(center: Vector3, size: Vector3, yaw: float = 0.0) -> void:
	colliders.append({"c": center, "s": size, "r": yaw})


func totals() -> int:
	return buildings.tri_count() + plates.tri_count() + streets.tri_count() \
		+ props.tri_count() + emissive.tri_count()
