## The knight's mace: the retuned swing wedge.
##
## This is the starter's arc-cone machinery (`canFireArc` / `startArcFire` /
## `resolveActiveArcCones` / `selectArcVictims`) with the victim set changed
## from enemy cogs to zombies and the geometry changed from a linearly
## widening spray cone to a fixed-half-angle wedge: `knightReach` px long,
## `knightArcBrads` brads either side of the aim locked at the swing, line of
## sight required.
##
## HASHED state, so INTEGER ONLY (see horde.nim's module note). The angle test
## is exact fixed point: a point is inside the wedge when
## `|perp| * cos(half) <= forward * sin(half)`, and both trig values are read
## straight out of the `AimUnitX/Y` literals at the half-angle index — so the
## predicate is a pair of `int64` products and nothing else.

import
  sim_types, sim_state

proc wedgeTanScale*(halfBrads: int): tuple[num, den: int] =
  ## `tan(halfBrads)` as an exact ratio of two table entries: sin over cos at
  ## the half-angle. Bounded to 1..63 brads by sim_config, so cos is always
  ## strictly positive and this never divides by zero.
  let b = clamp(halfBrads, 1, 63)
  (-AimUnitY[b], AimUnitX[b])

proc inWedge*(
  ax, ay, aimBrads, reach, halfBrads, tx, ty: int
): bool =
  ## Whether the point (tx, ty) lies inside the wedge at (ax, ay). Products
  ## are `int64`: a 1235 px offset times a 1024-scaled unit times the reach
  ## overflows a 32-bit `int` on wasm32.
  let b = ((aimBrads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
  let
    ux = int64(AimUnitX[b])
    uy = int64(AimUnitY[b])
    vx = int64(tx - ax)
    vy = int64(ty - ay)
    forward = vx * ux + vy * uy          ## scaled by AimUnitScale
    perp = vx * uy - vy * ux
  if forward <= 0:
    return false
  if forward > int64(reach) * int64(AimUnitScale):
    return false
  let (num, den) = wedgeTanScale(halfBrads)
  abs(perp) * int64(den) <= forward * int64(num)

proc knightSwingClear*(sim: SimServer, ax, ay, tx, ty: int): bool =
  ## Line of sight for a swing: the mace does not reach through a wall.
  let
    dx = tx - ax
    dy = ty - ay
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return true
  for s in 1 .. steps:
    let
      rx = ax + dx * s div steps
      ry = ay + dy * s div steps
    if rx < 0 or ry < 0 or rx >= MapWidth or ry >= MapHeight or
        sim.wallMask[mapIndex(rx, ry)]:
      return false
  true
