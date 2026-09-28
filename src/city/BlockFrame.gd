class_name BlockFrame
extends RefCounted
## A block's own orthonormal frame. Typed instead of a Dictionary so every consumer gets
## compile-time types — the lattice is warped, so nothing in the city is axis-aligned.

var c: Vector2 = Vector2.ZERO
var ax: Vector2 = Vector2.RIGHT
var az: Vector2 = Vector2(0, 1)
var ex: float = 0.0
var ez: float = 0.0
var area: float = 0.0


func make(oc: Vector2, ohx: float, ohz: float, rot: Vector2) -> BlockFrame:
	c = oc
	ax = rot
	az = Vector2(-rot.y, rot.x)
	ex = maxf(ohx, 1.0)
	ez = maxf(ohz, 1.0)
	area = ex * ez * 4.0
	return self


## Axis-aligned-ish rectangle in this frame.
func rect(x_off: float, z_off: float, hx: float, hz: float, extra_yaw: float = 0.0) -> PackedVector2Array:
	var a := ax
	var b := az
	if extra_yaw != 0.0:
		a = a.rotated(extra_yaw)
		b = b.rotated(extra_yaw)
	var ctr := c + a * x_off + b * z_off
	var q := PackedVector2Array()
	for pair in [[-hx, -hz], [hx, -hz], [hx, hz], [-hx, hz]]:
		q.append(ctr + a * pair[0] + b * pair[1])
	return q


func at(x_off: float, z_off: float) -> Vector2:
	return c + ax * x_off + az * z_off


func corner(i: int) -> Vector2:
	return at(-ex if (i == 0 or i == 3) else ex, -ez if (i < 2) else ez)


func outline() -> PackedVector2Array:
	var q := PackedVector2Array()
	for pair in [[-ex, -ez], [ex, -ez], [ex, ez], [-ex, ez]]:
		q.append(c + ax * pair[0] + az * pair[1])
	return q


func yaw() -> float:
	return atan2(-ax.x, ax.y)
