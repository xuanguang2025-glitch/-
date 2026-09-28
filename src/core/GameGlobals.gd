extends Node
## Central tuning table, input bindings and cross-system event bus.
## Every subsystem talks through these signals so nothing hard-references another.

# --- Event bus -------------------------------------------------------------
signal time_of_day_changed(hour: float)
signal weather_changed(kind: int, intensity: float)
signal game_mode_changed(previous: int, current: int)
signal spawn_requested(transform: Transform3D)
signal vehicle_entered(vehicle: Node)
signal vehicle_exited(vehicle: Node)
signal build_object_placed(record: Dictionary)
signal build_object_removed(id: int)
signal build_selection_changed(record: Dictionary)
signal economy_changed(cash: float)
signal landmark_discovered(name: String)
signal hud_message(text: String, duration: float)

# --- Enums -----------------------------------------------------------------
enum GameMode { PLAY, DRIVE, BUILD, PAUSED }
enum Weather { CLEAR, CLOUDY, OVERCAST, RAIN, STORM, FOG, TYPHOON }
enum RoadKind { HIGHWAY, RING, ARTERY, SUB_ARTERY, LOCAL, ALLEY, elevated, TUNNEL }
enum Surface { GROUND, ROAD, PAVEMENT, GRASS, PLAZA, WATER, CONCRETE }

# --- World metrics (1 unit = 1 metre) --------------------------------------
const WORLD_HALF := 6000.0          # playable span is 12 km x 12 km
const CHUNK_SIZE := 250.0
const CHUNKS_PER_AXIS := int(WORLD_HALF * 2.0 / CHUNK_SIZE)
const STREAM_RADIUS := 6            # mesh chunks kept alive around the origin of interest
const SIM_RADIUS := 3               # traffic / crowd agents alive inside this many chunks
const UNLOAD_PAD := 2

const EYE_HEIGHT := 1.65
const PLAYER_SPEED_WALK := 4.4
const PLAYER_SPEED_RUN := 9.2
const PLAYER_SPEED_SPRINT := 14.5
const PLAYER_JUMP := 5.4
const GRAVITY := 24.5

# --- Day / night -----------------------------------------------------------
const DAY_LENGTH_SEC := 480.0       # one in-game day at 1x
const SUNRISE_HOUR := 5.75
const SUNSET_HOUR := 18.6

# --- Seeded procedural noise ----------------------------------------------
var rng := RandomNumberGenerator.new()

var game_mode: int = GameMode.PLAY
var time_of_day: float = 17.4       # start in golden hour, dusk lights kick in
var time_scale: float = 1.0
var weather_kind: int = Weather.CLEAR
var weather_intensity: float = 0.0
var cash: float = 250000.0
var discovered: Dictionary = {}


func _ready() -> void:
	rng.seed = 0x5A4FE1
	process_mode = Node.PROCESS_MODE_ALWAYS
	_install_input_map()


# --- Input ------------------------------------------------------------------
const _KEYCODES := {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],
	"sprint": [KEY_SHIFT],
	"crouch": [KEY_CTRL],
	"interact": [KEY_E],
	"enter_vehicle": [KEY_F],
	"toggle_build": [KEY_B],
	"toggle_map": [KEY_M],
	"toggle_pause": [KEY_ESCAPE],
	"tool_rotate": [KEY_R],
	"tool_delete": [KEY_X],
	"tool_grid": [KEY_G],
	"tool_next": [KEY_TAB],
	"tool_prev": [KEY_SHIFT],
	"camera_mode": [KEY_C],
	"weather_next": [KEY_V],
	"time_faster": [KEY_T],
	"time_slower": [KEY_G],
	"horn": [KEY_H],
	"handbrake": [KEY_SPACE],
	"vehicle_reset": [KEY_Y],
	"fly_up": [KEY_SPACE],
	"fly_down": [KEY_SHIFT],
	"summon_vehicle": [KEY_1],
}


func _install_input_map() -> void:
	for action in _KEYCODES.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.35)
		for key in _KEYCODES[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
	# Mouse bindings live outside the keycode table.
	for pair in [
		["build_place", MOUSE_BUTTON_LEFT],
		["build_remove", MOUSE_BUTTON_RIGHT],
		["look", MOUSE_BUTTON_RIGHT],
	]:
		if not InputMap.has_action(pair[0]):
			InputMap.add_action(pair[0], 0.0)
		var mb := InputEventMouseButton.new()
		mb.button_index = pair[1]
		InputMap.action_add_event(pair[0], mb)


# --- State transitions ------------------------------------------------------
func set_mode(next: int) -> void:
	if next == game_mode:
		return
	var prev := game_mode
	game_mode = next
	game_mode_changed.emit(prev, next)


func set_time(hour: float) -> void:
	time_of_day = fposmod(hour, 24.0)
	time_of_day_changed.emit(time_of_day)


func advance_time(delta_hours: float) -> void:
	set_time(time_of_day + delta_hours)


func set_weather(kind: int, intensity: float = 1.0) -> void:
	weather_kind = kind
	weather_intensity = clampf(intensity, 0.0, 1.0)
	weather_changed.emit(weather_kind, weather_intensity)


func add_cash(amount: float) -> void:
	cash += amount
	economy_changed.emit(cash)


func say(text: String, duration: float = 3.0) -> void:
	hud_message.emit(text, duration)


# --- Deterministic helpers --------------------------------------------------
static func hash2(xi: int, yi: int, seed: int = 0) -> float:
	var n := xi * 374761393 + yi * 668265263 + seed * 1442695040
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float((n & 0x7fffffff) % 100000) / 100000.0


static func hash_range(xi: int, yi: int, lo: float, hi: float, seed: int = 0) -> float:
	return lo + hash2(xi, yi, seed) * (hi - lo)


static func smoothstep_edge(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / maxf(absf(edge1 - edge0), 0.0001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Value noise over an integer lattice, used for density falloff and roughness.
static func noise2(x: float, y: float, seed: int = 0) -> float:
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var fx := smoothstep_edge(0.0, 1.0, x - x0)
	var fy := smoothstep_edge(0.0, 1.0, y - y0)
	var a := hash2(x0, y0, seed)
	var b := hash2(x0 + 1, y0, seed)
	var c := hash2(x0, y0 + 1, seed)
	var d := hash2(x0 + 1, y0 + 1, seed)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


static func fbm(x: float, y: float, octaves: int = 3, seed: int = 0) -> float:
	var sum := 0.0
	var amp := 0.5
	var freq := 1.0
	var norm := 0.0
	for i in octaves:
		sum += noise2(x * freq, y * freq, seed + i * 101) * amp
		norm += amp
		amp *= 0.5
		freq *= 2.02
	return sum / maxf(norm, 0.0001)


func is_playing() -> bool:
	return game_mode == GameMode.PLAY or game_mode == GameMode.DRIVE
