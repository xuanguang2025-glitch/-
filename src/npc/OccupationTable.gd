class_name OccupationTable
extends RefCounted
## Shanghai's working population, expressed as data. Occupation decides where a person
## lives, where they work, what hours they keep, what they wear, and how they spend
## off-hours — which is what turns anonymous crowd dots into a city that has jobs.

enum Occ { OFFICE, TEACHER, STUDENT, DOCTOR, DRIVER, SHOPKEEPER, ENGINEER, WORKER,
	POLICE, TOURIST, RETIRED, CLEANER, GUARD, FREELANCE }

enum State { SLEEP, COMMUTE, WORK, LUNCH, LEISURE, SHOP, EXERCISE }

## zone keys index PopulationSystem's job pools.
const DATA := {
	Occ.OFFICE: {"label": "白领", "income": 15500.0, "work": Vector2(9.0, 18.0),
		"zone": "office", "weight": 20, "dress": [0, 1, 4, 7], "leisure": "retail"},
	Occ.ENGINEER: {"label": "工程师", "income": 21000.0, "work": Vector2(9.5, 19.0),
		"zone": "office", "weight": 8, "dress": [0, 4, 5], "leisure": "park"},
	Occ.TEACHER: {"label": "教师", "income": 11000.0, "work": Vector2(7.8, 16.5),
		"zone": "school", "weight": 5, "dress": [2, 4, 6], "leisure": "park"},
	Occ.STUDENT: {"label": "学生", "income": 0.0, "work": Vector2(8.0, 15.5),
		"zone": "school", "weight": 12, "dress": [5, 6, 7], "leisure": "park"},
	Occ.DOCTOR: {"label": "医护", "income": 19000.0, "work": Vector2(8.0, 18.0),
		"zone": "hospital", "weight": 4, "dress": [3], "leisure": "retail"},
	Occ.DRIVER: {"label": "司机", "income": 8500.0, "work": Vector2(6.5, 20.5),
		"zone": "industry", "weight": 9, "dress": [1, 5, 7], "leisure": "street"},
	Occ.SHOPKEEPER: {"label": "店主", "income": 12000.0, "work": Vector2(10.0, 22.0),
		"zone": "retail", "weight": 8, "dress": [2, 4, 6], "leisure": "retail"},
	Occ.WORKER: {"label": "工人", "income": 7800.0, "work": Vector2(7.5, 17.5),
		"zone": "industry", "weight": 10, "dress": [1, 5, 7], "leisure": "street"},
	Occ.POLICE: {"label": "民警", "income": 10500.0, "work": Vector2(8.0, 18.0),
		"zone": "civic", "weight": 3, "dress": [0, 5], "leisure": "street"},
	Occ.CLEANER: {"label": "环卫", "income": 5200.0, "work": Vector2(5.0, 13.0),
		"zone": "civic", "weight": 4, "dress": [6, 7], "leisure": "street"},
	Occ.GUARD: {"label": "保安", "income": 5800.0, "work": Vector2(7.0, 19.0),
		"zone": "civic", "weight": 5, "dress": [0, 5, 7], "leisure": "street"},
	Occ.RETIRED: {"label": "退休", "income": 6000.0, "work": Vector2(0.0, -1.0),
		"zone": "none", "weight": 9, "dress": [2, 3, 6], "leisure": "park"},
	Occ.TOURIST: {"label": "游客", "income": 0.0, "work": Vector2(0.0, -1.0),
		"zone": "none", "weight": 6, "dress": [4, 6, 7, 1], "leisure": "landmark"},
	Occ.FREELANCE: {"label": "自由职业", "income": 9000.0, "work": Vector2(11.0, 16.0),
		"zone": "office", "weight": 5, "dress": [2, 4, 6], "leisure": "retail"},
}

## Weighted pick so the population mix looks like a Chinese megacity, not a uniform sample.
const _CUM: Array = []
static var _built := false


static func occupations() -> Array:
	return DATA.keys()


static func roll(rnd: RandomNumberGenerator) -> int:
	var total := 0
	for k in DATA.keys():
		total += int(DATA[k]["weight"])
	var pick := rnd.randi_range(1, total)
	var acc := 0
	for k in DATA.keys():
		acc += int(DATA[k]["weight"])
		if pick <= acc:
			return k
	return Occ.OFFICE


static func label(occ: int) -> String:
	return String(DATA[occ]["label"])


static func zone(occ: int) -> String:
	return String(DATA[occ]["zone"])


static func income(occ: int) -> float:
	return float(DATA[occ]["income"])


## Working window; work.y < 0 means unemployed (retired / tourist).
static func shift(occ: int) -> Vector2:
	return DATA[occ]["work"]


static func is_worker(occ: int) -> bool:
	return float(DATA[occ]["work"].y) > 0.0


# --- Names ------------------------------------------------------------------
const SURNAMES := ["王", "李", "张", "刘", "陈", "杨", "黄", "赵", "吴", "周", "徐", "孙",
	"马", "朱", "胡", "郭", "何", "高", "林", "罗", "郑", "梁", "谢", "宋", "唐", "许",
	"韩", "冯", "邓", "曹", "彭", "曾", "肖", "田", "董", "潘", "袁", "蔡", "蒋", "余"]

const GIVEN1 := ["伟", "芳", "娜", "敏", "静", "磊", "强", "军", "洋", "勇", "艳", "杰",
	"娟", "涛", "明", "超", "秀", "霞", "平", "刚", "桂", "文", "辉", "丽", "晓", "玉兰",
	"建华", "国", "红", "春", "小", "志", "建", "思", "雨", "佳", "嘉", "子", "欣", "宇"]

const GIVEN2 := ["英", "华", "慧", "巧", "美", "玉", "萍", "婷", "燕", "彬", "新", "凯",
	"倩", "龙", "辰", "昊", "蕾", "琪", "瑶", "琳", "阳", "洁", "颖", "雪", "琴", "兰",
	""  , "", "", "", "", "", "", "", "", "", "", "", "", ""]


static func make_name(rnd: RandomNumberGenerator) -> String:
	var g := String(GIVEN1[rnd.randi_range(0, GIVEN1.size() - 1)])
	var g2 := String(GIVEN2[rnd.randi_range(0, GIVEN2.size() - 1)])
	return String(SURNAMES[rnd.randi_range(0, SURNAMES.size() - 1)]) + g + g2


## Age distribution skewed to working age, with the real city's retiree tail.
static func make_age(occ: int, rnd: RandomNumberGenerator) -> int:
	match occ:
		Occ.STUDENT:
			return rnd.randi_range(6, 22)
		Occ.RETIRED:
			return rnd.randi_range(56, 82)
		Occ.TOURIST:
			return rnd.randi_range(18, 60)
		Occ.OFFICE, Occ.ENGINEER, Occ.FREELANCE:
			return rnd.randi_range(23, 44)
		_:
			return rnd.randi_range(24, 58)


## Clothing palette. Index 0-7, mapped to colours that read at crowd distance.
const DRESS := [
	Color(0.13, 0.15, 0.22), Color(0.20, 0.24, 0.30), Color(0.42, 0.16, 0.14),
	Color(0.86, 0.86, 0.84), Color(0.30, 0.42, 0.62), Color(0.10, 0.11, 0.13),
	Color(0.62, 0.58, 0.48), Color(0.24, 0.36, 0.26),
]


static func dress_color(occ: int, rnd: RandomNumberGenerator) -> Color:
	var pool: Array = DATA[occ]["dress"]
	var c: Color = DRESS[int(pool[rnd.randi_range(0, pool.size() - 1)])]
	# Every outfit carries a lighter secondary so crowds do not read as flat blobs.
	return c.lightened(rnd.randf() * 0.18)
