class_name CreationZones
extends RefCounted
## Phase 163 / 161: where a player may build, and how big they may be.
##
## The spec's requirement is that upgrading the official Shanghai must not destroy player
## work, and symmetrically that player work must not overwrite the parts of the map that *are*
## the product — the Bund, Lujiazui, People's Square. So permission is a function of the city
## the generator already made: urban intensity plus landmark proximity, not a hand-typed table
## of coordinates that would go stale the first time the geography is recalibrated.
##
## Two consequences are enforced, because "permission" has to bind somewhere or it is a label:
##   - how large a footprint the zone allows
##   - how much terrain the zone allows the player to move
## Both are read by Validation, which is the single gate every generator passes through, so an
## AI planner cannot place something a hand-click could not.

enum Zone { OFFICIAL, PUBLIC, COMMUNITY, PRIVATE }

## Intensity cut-offs. 0.72 is the historic/CBD core; 0.45 the dense inner districts; 0.20 the
## suburbs. Measured against `CityData.intensity_at`, which peaks at 1.0 on People's Square.
const OFFICIAL_MIN := 0.72
const PUBLIC_MIN := 0.45
const COMMUNITY_MIN := 0.20

## A landmark's own protection radius: the postcard view stays official even where the
## intensity model would have already downgraded the surrounding block.
const LANDMARK_R := 220.0

## Largest half-footprint each zone permits, in metres. 9 m in the official core is a street
## prop or a sign, not a building; 80 m in a private zone is a full city block.
const MAX_HALF := {Zone.OFFICIAL: 9.0, Zone.PUBLIC: 26.0, Zone.COMMUNITY: 44.0, Zone.PRIVATE: 80.0}

## Terrain the player may move, in metres. The official core keeps its ground plane entirely:
## raising the Bund would change the skyline the base world is judged by.
const MAX_TERRAIN := {Zone.OFFICIAL: 0.0, Zone.PUBLIC: 2.0, Zone.COMMUNITY: 8.0, Zone.PRIVATE: 24.0}

const NAMES := {
	Zone.OFFICIAL: "官方核心区",
	Zone.PUBLIC: "公共建设区",
	Zone.COMMUNITY: "社区创作区",
	Zone.PRIVATE: "个人创作区",
}


static func label(z: int) -> String:
	return NAMES.get(z, "?")


static func zone_at(p: Vector2) -> Zone:
	if near_landmark(p):
		return Zone.OFFICIAL
	var k := CityData.intensity_at(p)
	if k >= OFFICIAL_MIN:
		return Zone.OFFICIAL
	if k >= PUBLIC_MIN:
		return Zone.PUBLIC
	if k >= COMMUNITY_MIN:
		return Zone.COMMUNITY
	return Zone.PRIVATE


static func max_half(p: Vector2) -> float:
	return float(MAX_HALF[zone_at(p)])


static func max_terrain_delta(p: Vector2) -> float:
	return float(MAX_TERRAIN[zone_at(p)])


## True when the point sits inside a landmark's protected view. Linear over 23 entries, which
## is fine for a placement click and would not be fine per ground sample.
static func near_landmark(p: Vector2) -> bool:
	for lm in CityData.LANDMARKS:
		var d := p.distance_to(Vector2(float(lm["x"]), float(lm["z"])))
		if d < LANDMARK_R:
			return true
	return false
