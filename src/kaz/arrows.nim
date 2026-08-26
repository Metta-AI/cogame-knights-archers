## The archer's arrows: the in-flight list and its resolution.
##
## This is the shape of the starter's hashed in-flight projectile list
## (`AirborneGrenade` / `updateGrenades`) — a `seq` of integer-positioned
## objects advanced once per tick, hashed, replayed and pruned — flying
## straight instead of lobbed, and hitting a body instead of exploding on
## landing.
##
## HASHED state, so INTEGER ONLY (see horde.nim's module note). Velocities come
## out of the fixed-point `AimUnitX/Y` tables; the swept-segment hit test uses
## the starter's own `segDistSqWithin`, which is already all-integer with
## `int64` intermediates.

import
  sim_types, sim_state

proc arrowPx*(arrow: Arrow): tuple[x, y: int] {.inline.} =
  (arrow.ux div MotionScale, arrow.uy div MotionScale)

proc arrowVelocityFor*(sim: SimServer, brads: int): tuple[vx, vy: int] =
  ## The motion-unit velocity of an arrow loosed along one aim angle. The
  ## direction is a lookup, never a cosine: a compile-time cos/sin would be
  ## evaluated by whichever libm the build container shipped and could differ
  ## by an ulp between the amd64 game image and the emscripten viewer image.
  let
    b = ((brads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
    speed = max(1, sim.config.arrowSpeed)
  (speed * AimUnitX[b] div AimUnitScale, speed * AimUnitY[b] div AimUnitScale)

proc pushArrow*(sim: var SimServer, owner, brads: int) =
  ## Looses one arrow from an archer's body centre. `MaxArrows` is a hard cap:
  ## the oldest is dropped if a 65th is fired (unreachable at a 12-tick
  ## cooldown and a 44-tick life — four archers hold at most sixteen).
  if owner < 0 or owner >= sim.players.len:
    return
  let (vx, vy) = sim.arrowVelocityFor(brads)
  if sim.arrows.len >= MaxArrows:
    sim.arrows.delete(0)
  sim.arrows.add Arrow(
    ux: (sim.players[owner].x + CollisionW div 2) * MotionScale,
    uy: (sim.players[owner].y + CollisionH div 2) * MotionScale,
    vx: vx,
    vy: vy,
    owner: owner,
    ticksLeft: max(1, sim.config.arrowLifeTicks)
  )

proc arrowWallHit*(
  sim: SimServer, fromX, fromY, toX, toY: int
): tuple[hit: bool, x, y: int] =
  ## The first wall pixel along the arrow's swept segment this tick, if any.
  result = (false, toX, toY)
  let
    dx = toX - fromX
    dy = toY - fromY
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return
  for s in 1 .. steps:
    let
      rx = fromX + dx * s div steps
      ry = fromY + dy * s div steps
    if rx < 0 or ry < 0 or rx >= MapWidth or ry >= MapHeight or
        sim.wallMask[mapIndex(rx, ry)]:
      return (true, rx, ry)
