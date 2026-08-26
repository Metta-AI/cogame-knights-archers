## The control layer: the ONE deterministic function that turns a directive
## into per-tick Sprite v1 actuator masks.
##
## Both LLM directives and scripted directives are compiled by this same code,
## so the two policy kinds are strictly comparable and a scripted baseline is
## legal by construction. It is a pure function of
## `(sim state, order, cogIndex) -> uint8`.
##
## It sits OUTSIDE the determinism boundary: the server records the masks this
## produces into the replay, and the wasm viewer feeds those recorded masks to
## the identical sim. Nothing here is re-run at playback.
##
## Legality is STRUCTURAL, not checked afterwards: Up and Down are chosen from
## one sign so they can never both be set (same for Left/Right), B and Select
## come from one signed error, and C is never touched — knights-archers places
## nothing C could throw.

import
  std/tables,
  bitworld/spriteprotocol,
  sim, directives

const
  NavCell* = 12               ## nav grid cell side, in px.
                              ## Sized to the ARENA: its corridors are ~26 px
                              ## wide for a 13 px footprint, so a coarser cell
                              ## has no open cell anywhere inside a gap
                              ## between two obstacles and the flow field
                              ## reports the whole far side of every obstacle
                              ## column UNREACHABLE. At 12 px every 26 px
                              ## corridor contains a cell centre with the full
                              ## footprint's clearance.
  FieldRefreshTicks* = 12     ## a flow field is recomputed at most this often.
  MaxCachedFields* = 64       ## flow fields kept before the cache is dropped.
  ArriveRadius* = 20          ## px: a hero this close to its goal stops moving.
  AimMinRangeSq* = 16 * 16    ## an aim target nearer than this gives a vector
                              ## too short to mean a direction.
  AimDeadBrads* = 4           ## no turn button inside this error.
  ArcherFireAimBrads* = 8     ## widest aim error an archer looses on.
  KnightAimRangePx* = 120     ## px: aim priority radius for a knight.
  ArcherAimRangePx* = 560     ## px: aim priority radius for an archer.
  StuckTicks* = 8             ## ticks of zero displacement after which a hero
                              ## steers along the obstacle instead of into it.
  ArcherProbePoints* = 16     ## standoff candidates probed around a target.

type
  NavGrid* = object
    w*, h*: int
    open*: seq[bool]

  ControlState* = object
    ## Everything the control layer remembers between ticks. Lives on the
    ## SERVER, never on the sim, so it can never enter gameHash.
    grid*: NavGrid
    fields*: Table[int, seq[int]]      ## goal cell -> BFS distance field
    fieldTick*: Table[int, int]        ## goal cell -> tick it was built
    lastX*, lastY*: seq[int]           ## per hero: position at the last observe
    stuckTicks*: seq[int]              ## per hero: consecutive motionless ticks

proc navCellOf*(grid: NavGrid, x, y: int): int =
  ## The flat nav cell containing a map pixel, or -1 off the grid.
  let
    cx = x div NavCell
    cy = y div NavCell
  if x < 0 or y < 0 or cx >= grid.w or cy >= grid.h:
    return -1
  cy * grid.w + cx

proc navCentre*(grid: NavGrid, cell: int): tuple[x, y: int] =
  ((cell mod grid.w) * NavCell + NavCell div 2,
   (cell div grid.w) * NavCell + NavCell div 2)

proc buildNavGrid*(sim: SimServer): NavGrid =
  ## A NavCell-px occupancy grid over the sim's REAL wall mask: a cell is open
  ## when a hero footprint fits at its centre. Built once per episode; a
  ## spinning diamond that later rotates into a cell this grid calls open is
  ## handled by the stuck deflection in `compileMask`.
  result.w = (MapWidth + NavCell - 1) div NavCell
  result.h = (MapHeight + NavCell - 1) div NavCell
  result.open = newSeq[bool](result.w * result.h)
  for cell in 0 ..< result.open.len:
    let (cx, cy) = result.navCentre(cell)
    if cx < MapWidth and cy < MapHeight:
      result.open[cell] = sim.canOccupy(cx, cy)

proc nearestOpenCell*(grid: NavGrid, x, y: int): int =
  ## The open cell nearest a map point, by expanding ring search. -1 only
  ## when the grid has no open cell at all.
  let start = grid.navCellOf(
    clamp(x, 0, MapWidth - 1), clamp(y, 0, MapHeight - 1))
  if start >= 0 and grid.open[start]:
    return start
  let
    sx = clamp(x, 0, MapWidth - 1) div NavCell
    sy = clamp(y, 0, MapHeight - 1) div NavCell
  for r in 1 .. (grid.w + grid.h):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          cx = sx + dx
          cy = sy + dy
        if cx < 0 or cy < 0 or cx >= grid.w or cy >= grid.h:
          continue
        let cell = cy * grid.w + cx
        if grid.open[cell]:
          return cell
  -1

proc computeField*(grid: NavGrid, goal: int): seq[int] =
  ## Breadth-first flow field to `goal` over 4-connected open cells: the
  ## number of steps from every cell to the goal, -1 where unreachable.
  result = newSeq[int](grid.open.len)
  for i in 0 ..< result.len:
    result[i] = -1
  if goal < 0 or goal >= result.len or not grid.open[goal]:
    return
  var
    queue = @[goal]
    head = 0
  result[goal] = 0
  while head < queue.len:
    let
      cell = queue[head]
      cx = cell mod grid.w
      cy = cell div grid.w
      d = result[cell]
    inc head
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= grid.w or ny >= grid.h:
        continue
      let next = ny * grid.w + nx
      if not grid.open[next] or result[next] >= 0:
        continue
      result[next] = d + 1
      queue.add(next)

proc fieldFor*(ctl: var ControlState, tick, goal: int): seq[int] =
  ## The cached flow field for one goal cell, rebuilt at most once every
  ## FieldRefreshTicks.
  if goal < 0:
    return @[]
  if ctl.fields.hasKey(goal) and
      tick - ctl.fieldTick.getOrDefault(goal, low(int) div 2) <
        FieldRefreshTicks:
    return ctl.fields[goal]
  if ctl.fields.len >= MaxCachedFields and not ctl.fields.hasKey(goal):
    ctl.fields.clear()
    ctl.fieldTick.clear()
  let field = computeField(ctl.grid, goal)
  ctl.fields[goal] = field
  ctl.fieldTick[goal] = tick
  field

proc navSteer*(
  ctl: var ControlState, tick, fromX, fromY, goalX, goalY: int
): tuple[dx, dy: int] =
  ## The steering vector for one hero: straight at the goal when the line of
  ## sight is clear, else down the flow field toward the neighbouring cell
  ## nearest the goal.
  let goalCell = ctl.grid.nearestOpenCell(goalX, goalY)
  if goalCell < 0:
    return (0, 0)
  let (gx, gy) = ctl.grid.navCentre(goalCell)
  let field = ctl.fieldFor(tick, goalCell)
  let here = ctl.grid.nearestOpenCell(fromX, fromY)
  if here < 0 or field.len == 0 or field[here] <= 1:
    return (gx - fromX, gy - fromY)
  let
    cx = here mod ctl.grid.w
    cy = here div ctl.grid.w
  var
    best = field[here]
    bestCell = -1
  for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1),
                   (1, 1), (1, -1), (-1, 1), (-1, -1)]:
    let
      nx = cx + dx
      ny = cy + dy
    if nx < 0 or ny < 0 or nx >= ctl.grid.w or ny >= ctl.grid.h:
      continue
    let next = ny * ctl.grid.w + nx
    if not ctl.grid.open[next] or field[next] < 0:
      continue
    if dx != 0 and dy != 0:
      # No corner cutting: a diagonal is only taken when both of the cells it
      # squeezes between are open. A cell is barely wider than a hero, so
      # clipping the corner of an obstacle wedges it against the stone.
      if not ctl.grid.open[cy * ctl.grid.w + nx] or
          not ctl.grid.open[ny * ctl.grid.w + cx]:
        continue
    if field[next] < best:
      best = field[next]
      bestCell = next
  if bestCell < 0:
    return (gx - fromX, gy - fromY)
  let (nxp, nyp) = ctl.grid.navCentre(bestCell)
  (nxp - fromX, nyp - fromY)

proc bradsErr*(desired, current: int): int =
  ## Signed shortest turn from `current` to `desired`, in brads: positive is
  ## counter-clockwise (button B), negative clockwise (button Select).
  var d = (desired - current) mod AimBradsTurn
  if d < -(AimBradsTurn div 2): d += AimBradsTurn
  if d > AimBradsTurn div 2: d -= AimBradsTurn
  d

proc initControlState*(sim: SimServer): ControlState =
  result.grid = buildNavGrid(sim)
  result.fields = initTable[int, seq[int]]()
  result.fieldTick = initTable[int, int]()
  result.lastX = newSeq[int](MaxPlayers)
  result.lastY = newSeq[int](MaxPlayers)
  result.stuckTicks = newSeq[int](MaxPlayers)
  for i in 0 ..< MaxPlayers:
    result.lastX[i] = low(int) div 2
    result.lastY[i] = low(int) div 2

proc observeHeroes*(ctl: var ControlState, sim: SimServer) =
  ## The control layer's ONCE-PER-TICK observation: whether each hero is
  ## making progress. Updated here rather than in `compileMask` so that
  ## compiling a mask stays a pure read of this state — the same
  ## (state, order) pair yields the same byte however many times it is asked.
  while ctl.lastX.len < sim.players.len:
    ctl.lastX.add(low(int) div 2)
    ctl.lastY.add(low(int) div 2)
    ctl.stuckTicks.add(0)
  for i in 0 ..< sim.players.len:
    if sim.players[i].x == ctl.lastX[i] and sim.players[i].y == ctl.lastY[i]:
      inc ctl.stuckTicks[i]
    else:
      ctl.stuckTicks[i] = 0
    ctl.lastX[i] = sim.players[i].x
    ctl.lastY[i] = sim.players[i].y

proc gateCentre*(sim: SimServer): tuple[x, y: int] =
  ## The gate's threshold centre: the middle of Red's home column, which the
  ## design pins as `[40, 329]` on the shipped arena.
  let zone = sim.captureZone(Red)
  (sim.config.gateX, (zone.yLo + zone.yHi) div 2)

proc leaderPos*(sim: SimServer): tuple[found: bool, x, y: int] =
  ## The live zombie with the smallest gate distance, in map pixels.
  let index = sim.leaderZombie()
  if index < 0:
    return (false, 0, 0)
  let (zx, zy) = sim.zombies[index].zombiePx()
  (true, zx, zy)

proc nearestZombieTo*(
  sim: SimServer, x, y: int
): tuple[found: bool, slot, x, y: int] =
  ## The live zombie nearest a point, ties to the lowest zombie id.
  result = (false, -1, 0, 0)
  var best = high(int)
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    let (zx, zy) = sim.zombies[i].zombiePx()
    let d = distSq(x, y, zx, zy)
    if d < best:
      best = d
      result = (true, i, zx, zy)

proc pointToward*(
  fromX, fromY, towardX, towardY, standoff: int
): tuple[x, y: int] =
  ## The point `standoff` px from (fromX, fromY) along the direction toward
  ## (towardX, towardY). All-integer, via horde.nim's `intRoot`.
  let
    dx = towardX - fromX
    dy = towardY - fromY
    len = intRoot(dx * dx + dy * dy)
  if len <= 0:
    return (fromX, fromY)
  (clamp(fromX + dx * standoff div len, 0, MapWidth - 1),
   clamp(fromY + dy * standoff div len, 0, MapHeight - 1))

proc archerStandoff*(
  sim: SimServer, targetX, targetY, gateX, gateY, radius: int
): tuple[x, y: int] =
  ## The first clear standoff point found by probing `ArcherProbePoints`
  ## evenly spaced points on the circle of `radius` px around the target,
  ## starting from the direction of target -> gate and alternating outward,
  ## requiring a clear line to the target and walkable ground. If none is
  ## clear the archer walks at the target — it would rather be in the fight
  ## than nowhere.
  let start = bradsOfVector(gateX - targetX, gateY - targetY)
  for step in 0 ..< ArcherProbePoints:
    let
      half = (step + 1) div 2
      sign = if step mod 2 == 0: 1 else: -1
      brads = ((start + sign * half * (AimBradsTurn div ArcherProbePoints)) mod
        AimBradsTurn + AimBradsTurn) mod AimBradsTurn
      px = clamp(
        targetX + radius * AimUnitX[brads] div AimUnitScale, 0, MapWidth - 1)
      py = clamp(
        targetY + radius * AimUnitY[brads] div AimUnitScale, 0, MapHeight - 1)
    if sim.canOccupy(px, py) and sim.lineOfSightClear(px, py, targetX, targetY):
      return (px, py)
  (targetX, targetY)

proc archerHoldsPosition(
  sim: SimServer, cogIndex, targetX, targetY: int
): bool =
  ## An archer that already has a clear shot inside `arrowRange` does not
  ## advance. Walking toward a standoff ring that happens to sit EAST of the
  ## archer is how a bow seat dies: it crosses inside the 90 px lunge radius of
  ## a zombie it is not shooting at, and a charge covers 144 px inside one
  ## 4 s turn. Measured, that killed the archer seat in every `phalanx`
  ## episode; standing still whenever the shot is already there does not.
  let
    hero = sim.players[cogIndex]
    px = hero.x + CollisionW div 2
    py = hero.y + CollisionH div 2
    reach = max(1, sim.config.arrowRange)
  distSq(px, py, targetX, targetY) <= reach * reach and
    sim.lineOfSightClear(px, py, targetX, targetY)

proc awayFromTheHorde(
  sim: SimServer, cogIndex, goalX, goalY, gateX, gateY: int
): tuple[x, y: int] =
  ## A goal point inside a zombie's lunge radius is not a place to stand. Pull
  ## it back along the gate direction until it clears every live body, bounded
  ## so the search always terminates.
  result = (goalX, goalY)
  let keep = sim.config.zombieLungePx + 30
  for _ in 0 ..< 8:
    var worst = -1
    for i in 0 ..< sim.zombies.len:
      if not sim.zombies[i].alive:
        continue
      let (zx, zy) = sim.zombies[i].zombiePx()
      if distSq(result.x, result.y, zx, zy) <= keep * keep:
        worst = i
        break
    if worst < 0:
      return
    result = pointToward(result.x, result.y, gateX, gateY, keep)

proc goalFor*(
  ctl: ControlState, sim: SimServer, order: CogOrder, cogIndex: int
): tuple[x, y: int] =
  ## The goal point one intent resolves to for one hero. Every branch has a
  ## defined answer, so a hero is never left without somewhere to be.
  let
    hero = sim.players[cogIndex]
    px = hero.x + CollisionW div 2
    py = hero.y + CollisionH div 2
    gate = gateCentre(sim)
    knight = sim.isKnight(cogIndex)
    standoff = max(0, sim.config.roleStandoff)
  case order.intent
  of intIntercept:
    let leader = leaderPos(sim)
    if not leader.found:
      return (order.targetX, order.targetY)
    if knight:
      # STAND OFF INSIDE THE MACE'S REACH, not on top of the zombie. The
      # design note's `roleStandoff` = 0 for a knight ("walk onto it") is
      # lethal in practice: a hero dies to a body centre within 26 px, so a
      # knight ordered onto the leader walks through its own kill radius into
      # the zombie's, and a measured `phalanx` x4 episode ended `casualty`
      # after two kills. Holding `knightReach - 8` px out keeps the zombie
      # inside the 52 px wedge (it walks into the swing) and outside the 26 px
      # touch, which is the whole point of trading range for a one-shot.
      pointToward(
        leader.x, leader.y, gate.x, gate.y,
        max(1, sim.config.knightReach - 8))
    elif archerHoldsPosition(sim, cogIndex, leader.x, leader.y):
      (px, py)
    else:
      # Back off onto the GATE side of the leader and shoot from there.
      sim.awayFromTheHorde(
        cogIndex,
        pointToward(leader.x, leader.y, gate.x, gate.y, standoff).x,
        pointToward(leader.x, leader.y, gate.x, gate.y, standoff).y,
        gate.x, gate.y)
  of intHold:
    (order.targetX, order.targetY)
  of intScreen:
    let leader = leaderPos(sim)
    if not leader.found:
      return (order.targetX, order.targetY)
    let spot = pointToward(
      leader.x, leader.y, gate.x, gate.y, max(0, sim.config.screenStandoff))
    sim.nearestWalkable(spot.x, spot.y)
  of intFocus:
    let target = nearestZombieTo(sim, order.targetX, order.targetY)
    if not target.found:
      return (order.targetX, order.targetY)
    if knight:
      pointToward(
        target.x, target.y, gate.x, gate.y,
        max(1, sim.config.knightReach - 8))
    elif archerHoldsPosition(sim, cogIndex, target.x, target.y):
      (px, py)
    else:
      let spot = sim.archerStandoff(
        target.x, target.y, gate.x, gate.y, max(1, sim.config.archerRange))
      sim.awayFromTheHorde(cogIndex, spot.x, spot.y, gate.x, gate.y)
  of intFallBack:
    let zone = sim.captureZone(Red)
    (clamp(order.targetX, zone.xLo, zone.xHi),
     clamp(order.targetY, zone.yLo, zone.yHi))
  of intRegroup:
    var
      sx = 0
      sy = 0
      n = 0
    for i in 0 ..< sim.players.len:
      if i == cogIndex or not sim.players[i].alive:
        continue
      sx += sim.players[i].x + CollisionW div 2
      sy += sim.players[i].y + CollisionH div 2
      inc n
    if n == 0: (gate.x, gate.y)
    else: (sx div n, sy div n)

proc aimTargetFor(
  sim: SimServer, order: CogOrder, cogIndex: int, goalX, goalY: int
): tuple[x, y: int] =
  ## The aim point, in priority order: the nearest live zombie inside the
  ## role's aim range with a clear path — for an archer, its PREDICTED
  ## position, which is what makes an archer connect on a moving target —
  ## else the order's `face`, else the direction of the goal, else due EAST,
  ## the direction the horde comes from.
  let
    hero = sim.players[cogIndex]
    px = hero.x + CollisionW div 2
    py = hero.y + CollisionH div 2
    knight = sim.isKnight(cogIndex)
    range = if knight: KnightAimRangePx else: ArcherAimRangePx
  var
    best = high(int)
    bestX = 0
    bestY = 0
    found = false
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    var (zx, zy) = sim.zombies[i].zombiePx()
    let d = distSq(px, py, zx, zy)
    if d > range * range:
      continue
    if not knight:
      # Lead the target: pos + vel * (dist / arrowSpeed), in integers. A
      # marching zombie's velocity is one flow-field step, so this is that
      # step scaled by the number of ticks the arrow needs to arrive.
      let
        ticks = intRoot(d) * MotionScale div max(1, sim.config.arrowSpeed)
        dir = sim.fieldStep(zx, zy)
      if dir.found:
        let step = unitStep(
          dir.toX - zx, dir.toY - zy, sim.config.zombieSpeed * ticks)
        zx = clamp(zx + step.ux div MotionScale, 0, MapWidth - 1)
        zy = clamp(zy + step.uy div MotionScale, 0, MapHeight - 1)
    if not sim.lineOfSightClear(px, py, zx, zy):
      continue
    if d < best:
      best = d
      bestX = zx
      bestY = zy
      found = true
  if found:
    return (bestX, bestY)
  if order.hasFace:
    return (order.faceX, order.faceY)
  if distSq(px, py, goalX, goalY) > AimMinRangeSq:
    return (goalX, goalY)
  (MapWidth - 1, py)

proc knightWouldLand(sim: SimServer, cogIndex: int): bool =
  ## A knight sets A only when a live zombie's centre is inside the wedge
  ## around its CURRENT aim, with a clear path.
  let
    hero = sim.players[cogIndex]
    px = hero.x + CollisionW div 2
    py = hero.y + CollisionH div 2
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    let (zx, zy) = sim.zombies[i].zombiePx()
    if not inWedge(px, py, hero.aimBrads, sim.config.knightReach,
        sim.config.knightArcBrads, zx, zy):
      continue
    if sim.knightSwingClear(px, py, zx, zy):
      return true
  false

proc arrowWouldLand(sim: SimServer, cogIndex: int): bool =
  ## An archer sets A only when some live zombie's PREDICTED centre lies
  ## within `arrowHitRadius + 10` px of the aim ray inside `arrowRange`, with
  ## a clear path. It therefore only spends an arrow it expects to land, which
  ## is why two archers out-kill four at the same shot rate.
  let
    hero = sim.players[cogIndex]
    px = hero.x + CollisionW div 2
    py = hero.y + CollisionH div 2
    brads = ((hero.aimBrads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
    reach = max(1, sim.config.arrowRange)
    endX = clamp(
      px + reach * AimUnitX[brads] div AimUnitScale, 0, MapWidth - 1)
    endY = clamp(
      py + reach * AimUnitY[brads] div AimUnitScale, 0, MapHeight - 1)
    slack = sim.config.arrowHitRadius + 10
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    var (zx, zy) = sim.zombies[i].zombiePx()
    let d2 = distSq(px, py, zx, zy)
    if d2 > reach * reach:
      continue
    let
      ticks = intRoot(d2) * MotionScale div max(1, sim.config.arrowSpeed)
      dir = sim.fieldStep(zx, zy)
    if dir.found:
      let step = unitStep(
        dir.toX - zx, dir.toY - zy, sim.config.zombieSpeed * ticks)
      zx = clamp(zx + step.ux div MotionScale, 0, MapWidth - 1)
      zy = clamp(zy + step.uy div MotionScale, 0, MapHeight - 1)
    if not segDistSqWithin(zx, zy, px, py, endX, endY, slack * slack):
      continue
    if sim.lineOfSightClear(px, py, zx, zy):
      return true
  false

proc compileMask*(
  ctl: var ControlState,
  sim: SimServer,
  order: CogOrder,
  cogIndex: int
): uint8 =
  ## One hero's Sprite v1 actuator mask for this tick.
  result = 0
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let hero = sim.players[cogIndex]
  if not hero.alive:
    return
  let
    px = hero.x + CollisionW div 2
    py = hero.y + CollisionH div 2
    goal = ctl.goalFor(sim, order, cogIndex)

  # --- d-pad: the octant of the steering vector, unless we have arrived ---
  if distSq(px, py, goal.x, goal.y) > ArriveRadius * ArriveRadius:
    var steer = ctl.navSteer(sim.tickCount, px, py, goal.x, goal.y)
    if cogIndex < ctl.stuckTicks.len and
        ctl.stuckTicks[cogIndex] >= StuckTicks:
      # Wedged: steer a quarter turn clockwise instead, which slides the hero
      # ALONG whatever it is pressed against — another hero, a diamond that
      # has rotated into the lane, a wall the once-built field could not see.
      # One consistent rotation makes this a wall follower, so a convex
      # obstacle is always escaped rather than oscillated against.
      steer = (dx: -steer.dy, dy: steer.dx)
    let
      ax = abs(steer.dx)
      ay = abs(steer.dy)
      major = max(ax, ay)
    if major > 0:
      # Diagonals only when the minor axis is at least 40 % of the major one,
      # so a straight run does not chatter between two octants.
      if ax * 5 >= major * 2:
        result = result or (if steer.dx > 0: ButtonRight else: ButtonLeft)
      if ay * 5 >= major * 2:
        result = result or (if steer.dy > 0: ButtonDown else: ButtonUp)

  # --- aim ---
  let
    aim = aimTargetFor(sim, order, cogIndex, goal.x, goal.y)
    desired = bradsOfVector(aim.x - px, aim.y - py)
    err = bradsErr(desired, hero.aimBrads)
  if err > AimDeadBrads:
    result = result or ButtonB          ## counter-clockwise
  elif err < -AimDeadBrads:
    result = result or ButtonSelect     ## clockwise

  # --- trigger ---
  if order.intent == intFallBack:
    return
  if not sim.heroWeaponReady(cogIndex):
    return
  if sim.isKnight(cogIndex):
    if sim.knightWouldLand(cogIndex):
      result = result or ButtonA
  else:
    if abs(err) <= ArcherFireAimBrads and sim.arrowWouldLand(cogIndex):
      result = result or ButtonA
