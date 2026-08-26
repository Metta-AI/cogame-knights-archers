## The horde: the zombie list, the spawn schedule, the gate flow field, the
## march, the lunge, the fatal touch and the pressure metric.
##
## Everything in this module is HASHED state — the wasm replay viewer
## re-derives every zombie tick for tick from the recorded input masks and the
## config seed, and nothing about the horde is ever recorded — so every line of
## arithmetic here is INTEGER ONLY (`int64` intermediates where a product can
## grow). Nim's `int` is 32-bit under `--cpu:wasm32`, and a float direction
## would additionally depend on whichever libm the build container shipped, so
## directions come out of the fixed-point `AimUnitX/Y` literals in
## sim_types.nim and out of `intRoot` below, never out of `sqrt`/`arctan2`.
##
## Positions are in MOTION UNITS (px * MotionScale). A 384-unit step is exactly
## 1.5 px/tick with no accumulator and no rounding drift, and the pixel centre
## is one integer division away.
##
## Ownership of the seam: this module owns the HORDE (the list, the field, the
## schedule, the pressure numbers). The contact rule that kills a hero and the
## wave-end checks that read these numbers live in sim.nim, because they also
## need that module's kill/finish machinery.

import
  std/random,
  sim_types, arena, sim_state

const
  FieldDirs* = [
    (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]
    ## The eight flow-field neighbours in the design's tie-break order —
    ## N, NE, E, SE, S, SW, W, NW — so a zombie facing two equally good cells
    ## always takes the lower index and the choice is total and deterministic.
  DiagUnit* = 724
    ## round(1024 / sqrt 2), the diagonal component of a unit step at
    ## AimUnitScale. A literal, not a computation: see the module note.

proc intRoot*(value: int): int =
  ## Integer square root, floor, by Newton iteration. No `sqrt`, no float:
  ## the value feeds a hashed direction and must be bit-identical on wasm32
  ## and amd64.
  if value <= 0:
    return 0
  if value < 4:
    return 1
  var
    guess = value
    next = (value + 1) div 2
  while next < guess:
    guess = next
    next = (guess + value div guess) div 2
  guess

proc zombiePx*(zombie: Zombie): tuple[x, y: int] {.inline.} =
  ## One zombie's body centre in map pixels.
  (zombie.ux div MotionScale, zombie.uy div MotionScale)

proc hordeCellOf*(sim: SimServer, x, y: int): int {.inline.} =
  ## The flat zombieField cell containing a map pixel, or -1 off the grid.
  if sim.zombieFieldW <= 0 or sim.zombieFieldH <= 0:
    return -1
  let
    cx = x div HordeNavCell
    cy = y div HordeNavCell
  if x < 0 or y < 0 or cx >= sim.zombieFieldW or cy >= sim.zombieFieldH:
    return -1
  cy * sim.zombieFieldW + cx

proc hordeCellCentre*(sim: SimServer, cell: int): tuple[x, y: int] {.inline.} =
  ((cell mod sim.zombieFieldW) * HordeNavCell + HordeNavCell div 2,
   (cell div sim.zombieFieldW) * HordeNavCell + HordeNavCell div 2)

proc gateDistPx*(sim: SimServer, x, y: int): int =
  ## A point's distance to the gate ALONG THE FLOW FIELD, in pixels. A zombie
  ## behind a wall is not "close" just because its x is small, which is the
  ## whole reason the pressure metric reads this and not the raw column.
  ## An off-field or unreachable point reports the spawn distance, so the
  ## pressure bar can never read as danger for a zombie nobody can reach.
  let cell = sim.hordeCellOf(x, y)
  if cell < 0 or cell >= sim.zombieField.len or sim.zombieField[cell] < 0:
    return max(1, sim.spawnGateDist)
  sim.zombieField[cell] * HordeNavCell

proc gateDistOf*(sim: SimServer, zombie: Zombie): int {.inline.} =
  let (px, py) = zombie.zombiePx()
  sim.gateDistPx(px, py)

proc installHordeField*(sim: var SimServer) =
  ## Builds, ONCE per map install, the three static things the horde needs:
  ##
  ## * `zombieFieldNodeX/Y` — per HordeNavCell cell, the walkable pixel nearest
  ##   its centre. A cell is OPEN when it has one. Openness is deliberately not
  ##   "the centre is walkable": the arena's corridors are ~26 px wide inside a
  ##   34 px cell, so a centre-only test closes cells that a body walks
  ##   straight through and the field then reports whole regions of the board
  ##   unreachable — measured, a zombie spawned into one of those regions
  ##   walked into a wall and stayed there for the whole wave.
  ## * `zombieField` — an integer BFS distance field over those cells, seeded
  ##   from every cell inside `captureZone(Red)` (the gate) and expanded
  ##   8-connected at unit cost. A zombie steps toward the neighbouring cell
  ##   with the lowest value, aiming at that cell's NODE.
  ## * `spawnRows` — every y on the breach column at which a hero-sized body
  ##   box is clear floor with the spinning diamonds at spin frame 0, AND from
  ##   which the gate is reachable. A row a zombie could never march out of is
  ##   not a spawn.
  ##
  ## All three are pure functions of the installed `mapSpec`, so the native
  ## server and the wasm viewer install exactly the same lists and none of them
  ## is recorded.
  sim.zombieFieldW = (MapWidth + HordeNavCell - 1) div HordeNavCell
  sim.zombieFieldH = (MapHeight + HordeNavCell - 1) div HordeNavCell
  let cells = sim.zombieFieldW * sim.zombieFieldH
  sim.zombieField = newSeq[int](cells)
  sim.zombieFieldNodeX = newSeq[int](cells)
  sim.zombieFieldNodeY = newSeq[int](cells)
  for cell in 0 ..< cells:
    sim.zombieField[cell] = -1
    sim.zombieFieldNodeX[cell] = -1
    sim.zombieFieldNodeY[cell] = -1
  # The node search walks the cell's pixels outward from the centre, so the
  # node is the walkable pixel a body would actually use to cross the cell.
  for cell in 0 ..< cells:
    let
      cx0 = (cell mod sim.zombieFieldW) * HordeNavCell
      cy0 = (cell div sim.zombieFieldW) * HordeNavCell
      mid = HordeNavCell div 2
    block findNode:
      for r in 0 .. mid:
        for dy in -r .. r:
          for dx in -r .. r:
            if r > 0 and abs(dx) != r and abs(dy) != r:
              continue
            let
              px = cx0 + mid + dx
              py = cy0 + mid + dy
            if px < cx0 or py < cy0 or
                px >= cx0 + HordeNavCell or py >= cy0 + HordeNavCell:
              continue
            if px >= MapWidth or py >= MapHeight:
              continue
            if sim.canOccupy(px, py):
              sim.zombieFieldNodeX[cell] = px
              sim.zombieFieldNodeY[cell] = py
              break findNode
  ## Seeded from the GATE LINE, not from the whole home column. On the shipped
  ## arena `captureZone(Red)` is 207 px wide, so seeding the column would make
  ## the field FLAT over a third of the board: every zombie inside it would
  ## read gate distance 0, the pressure bar would peg at 100 % a hundred
  ## pixels early, and — measured — a zombie that walked into the column found
  ## no lower neighbour and simply stopped, so the wave could never end on a
  ## breach at all. The gate is the line the design pins, `config.gateX`.
  var queue: seq[int] = @[]
  let gateLine = max(1, sim.config.gateX)
  for cell in 0 ..< cells:
    if sim.zombieFieldNodeX[cell] < 0:
      continue
    if sim.zombieFieldNodeX[cell] <= gateLine:
      sim.zombieField[cell] = 0
      queue.add(cell)
  var head = 0
  while head < queue.len:
    let
      cell = queue[head]
      cx = cell mod sim.zombieFieldW
      cy = cell div sim.zombieFieldW
      d = sim.zombieField[cell]
    inc head
    for (dx, dy) in FieldDirs:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= sim.zombieFieldW or ny >= sim.zombieFieldH:
        continue
      let next = ny * sim.zombieFieldW + nx
      if sim.zombieFieldNodeX[next] < 0 or sim.zombieField[next] >= 0:
        continue
      if dx != 0 and dy != 0:
        ## No corner cutting: a diagonal only connects when both of the cells
        ## it squeezes between are open. A cell is barely wider than a body,
        ## so a diagonal through the corner of an obstacle is an edge the BFS
        ## can traverse and a zombie cannot -- which is exactly how a march
        ## ends up pressed into stone.
        if sim.zombieFieldNodeX[cy * sim.zombieFieldW + nx] < 0 or
            sim.zombieFieldNodeX[ny * sim.zombieFieldW + cx] < 0:
          continue
      sim.zombieField[next] = d + 1
      queue.add(next)

  sim.spawnRows = @[]
  let
    spawnX = clamp(
      sim.config.zombieSpawnX, PlayerHalf, MapWidth - 1 - PlayerHalf)
    yLo = ArenaBorder + PlayerHalf
    yHi = MapHeight - 1 - ArenaBorder - PlayerHalf
  for y in yLo .. yHi:
    if not sim.canOccupy(spawnX, y):
      continue
    let cell = sim.hordeCellOf(spawnX, y)
    if cell < 0 or sim.zombieField[cell] < 0:
      continue
    sim.spawnRows.add(y)
  sim.spawnGateDist = 1
  for y in sim.spawnRows:
    let d = sim.gateDistPx(spawnX, y)
    if d > sim.spawnGateDist:
      sim.spawnGateDist = d
  ## THE MAP-INSTALL ASSERTION (design.md:139). A breach column with too few
  ## clear, gate-reachable rows is not a knights-archers map: the horde would
  ## arrive in a single file down one lane, or -- with none at all --
  ## `spawnOneZombie` would have nowhere to put a body. It was previously
  ## checked only by tests/test_horde.nim (r1 review N8), which says nothing
  ## about a variant that installs a different map. This is install time, once
  ## per map, on a pure function of the mapSpec: it can only fire on a map that
  ## could never be played.
  if sim.spawnRows.len < MinSpawnRows:
    raise newException(SimGuardError,
      "map install: the breach column has " & $sim.spawnRows.len &
      " clear gate-reachable spawn rows, want at least " & $MinSpawnRows)

proc resetHorde*(sim: var SimServer) =
  ## Clears the horde, the arrows and every per-wave counter. Called from
  ## `resetToLobby` between the episode's waves, so wave two starts from a
  ## clean board on the same RNG stream (no re-seed — the design pins that).
  sim.zombies.setLen(0)
  sim.arrows.setLen(0)
  sim.zombieNextId = 0
  sim.spawnAcc = 0
  sim.aliveZombies = 0
  sim.zombiesSpawned = 0
  sim.waveKillsSoFar = 0
  sim.minGateDist = max(1, sim.spawnGateDist)
  sim.minGateTick = -1
  ## A FIXED literal, never `low(int) div 2`: this field is HASHED, and
  ## `low(int)` is -2^31 on the wasm32 viewer against -2^63 on the native
  ## server — so the two disagreed on the very first tick's hash and the
  ## native/wasm gate failed at tick 1 with nothing else wrong. Any sentinel
  ## far enough below zero that the 48-tick throttle reads "never" works;
  ## this one is portable.
  sim.lastCloseCallTick = -1_000_000
  sim.waveCasualty = -1
  sim.breachZombie = -1

proc spawnRatePerMille*(sim: SimServer, elapsed: int): int =
  ## The design's ramp, in per-mille of a zombie per tick:
  ##   start + (max - start) * min(t, saturate) / saturate
  let
    start = sim.config.spawnStartPerMille
    top = sim.config.spawnMaxPerMille
    saturate = max(1, sim.config.spawnSaturateTicks)
    t = clamp(elapsed, 0, saturate)
  start + (top - start) * t div saturate

proc spawnOneZombie*(sim: var SimServer) =
  ## Pushes one zombie at the breach column on a row drawn from the
  ## DETERMINISTIC sim RNG — the seed is in the config, the config is in the
  ## replay, so a replay re-derives every spawn.
  if sim.zombies.len >= MaxZombies or sim.spawnRows.len == 0:
    return
  let
    row = sim.spawnRows[sim.rng.rand(sim.spawnRows.len - 1)]
    spawnX = clamp(
      sim.config.zombieSpawnX, PlayerHalf, MapWidth - 1 - PlayerHalf)
  sim.zombies.add Zombie(
    id: sim.zombieNextId,
    ux: spawnX * MotionScale,
    uy: row * MotionScale,
    hp: max(1, sim.config.zombieHp),
    lungeTarget: -1,
    stuckTicks: 0,
    stuckRotTicks: 0,
    alive: true
  )
  inc sim.zombieNextId
  inc sim.zombiesSpawned
  inc sim.aliveZombies

proc spawnZombies*(sim: var SimServer) =
  ## Advances the per-mille accumulator and lets it fire. The accumulator
  ## keeps running while the board is at `spawnCapAlive`, so pressure held
  ## back by a full board is DEFERRED, not lost.
  sim.spawnAcc += sim.spawnRatePerMille(sim.gameTicksElapsed())
  while sim.spawnAcc >= 1000:
    sim.spawnAcc -= 1000
    if sim.aliveZombies >= sim.config.spawnCapAlive:
      continue
    sim.spawnOneZombie()

proc zombieCanStand*(sim: SimServer, px, py: int): bool {.inline.} =
  ## A zombie body fits here. Zombies collide with WALLS and never with each
  ## other: a lane of dead reads as a mass, not a queue.
  sim.canOccupy(px, py)

proc stepZombieAxis(
  sim: SimServer, zombie: var Zombie, stepUx, stepUy: int
): bool =
  ## Moves one zombie by a motion-unit step with the starter's own slide
  ## behaviour: try the whole step, else each axis alone, else nothing.
  ## Returns whether it actually moved.
  let
    fromX = zombie.ux div MotionScale
    fromY = zombie.uy div MotionScale
    toUx = zombie.ux + stepUx
    toUy = zombie.uy + stepUy
  if sim.zombieCanStand(toUx div MotionScale, toUy div MotionScale):
    zombie.ux = toUx
    zombie.uy = toUy
    return (toUx div MotionScale) != fromX or (toUy div MotionScale) != fromY
  if stepUx != 0 and
      sim.zombieCanStand(toUx div MotionScale, zombie.uy div MotionScale):
    zombie.ux = toUx
    return (toUx div MotionScale) != fromX
  if stepUy != 0 and
      sim.zombieCanStand(zombie.ux div MotionScale, toUy div MotionScale):
    zombie.uy = toUy
    return (toUy div MotionScale) != fromY
  false

proc nearestLungeHero*(sim: SimServer, px, py: int): int =
  ## The living hero within `zombieLungePx` of this point, nearest first,
  ## ties to the lowest cog index. -1 when nobody is close enough.
  result = -1
  let reachSq = sim.config.zombieLungePx * sim.config.zombieLungePx
  var best = high(int)
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    let d = distSq(px, py,
      sim.players[i].x + CollisionW div 2, sim.players[i].y + CollisionH div 2)
    if d <= reachSq and d < best:
      best = d
      result = i

proc unitStep*(dx, dy, speed: int): tuple[ux, uy: int] =
  ## A `speed`-long motion-unit step along an arbitrary integer direction,
  ## normalised with `intRoot`. All-integer; `int64` intermediates because a
  ## 1235 px offset times a 3072-unit speed overflows 32 bits.
  if dx == 0 and dy == 0:
    return (0, 0)
  let len = intRoot(dx * dx + dy * dy)
  if len <= 0:
    return (0, 0)
  (int(int64(dx) * int64(speed) div int64(len)),
   int(int64(dy) * int64(speed) div int64(len)))

proc fieldStep*(
  sim: SimServer, px, py: int
): tuple[toX, toY: int, found: bool] =
  ## The NODE of the neighbouring cell with the lowest field value, ties to the
  ## lowest FieldDirs index — N, NE, E, SE, S, SW, W, NW — so the choice is
  ## total and deterministic. `found` is false when the zombie is already on
  ## the gate cell or off the field entirely.
  result = (0, 0, false)
  let here = sim.hordeCellOf(px, py)
  if here < 0 or here >= sim.zombieField.len:
    return
  let
    cx = here mod sim.zombieFieldW
    cy = here div sim.zombieFieldW
  var best =
    if sim.zombieField[here] >= 0: sim.zombieField[here] else: high(int)
  for (dx, dy) in FieldDirs:
    let
      nx = cx + dx
      ny = cy + dy
    if nx < 0 or ny < 0 or nx >= sim.zombieFieldW or ny >= sim.zombieFieldH:
      continue
    let next = ny * sim.zombieFieldW + nx
    if sim.zombieField[next] < 0:
      continue
    if sim.zombieField[next] < best:
      best = sim.zombieField[next]
      result = (sim.zombieFieldNodeX[next], sim.zombieFieldNodeY[next], true)
  if not result.found and sim.zombieField[here] < 0:
    ## Off the reachable field entirely (a pocket the gate cannot see): walk
    ## WEST, which is the direction the gate is in on every shipped board.
    ## Degrade-never-hang applies to a zombie as much as to a network call.
    result = (max(0, px - HordeNavCell), py, true)

proc updateZombies*(sim: var SimServer) =
  ## One march tick, in zombie-id order: pick the lunge target, step along the
  ## lunge vector or the flow field, slide off walls, and rotate a quarter
  ## turn clockwise after `zombieStuckTicks` blocked ticks — the same
  ## wall-follower trick control.nim uses on wedged cogs, and for the same
  ## reason.
  let speed = max(1, sim.config.zombieSpeed)
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    let
      px = sim.zombies[i].ux div MotionScale
      py = sim.zombies[i].uy div MotionScale
      hero = sim.nearestLungeHero(px, py)
    sim.zombies[i].lungeTarget = hero
    var step: tuple[ux, uy: int]
    if hero >= 0:
      step = unitStep(
        sim.players[hero].x + CollisionW div 2 - px,
        sim.players[hero].y + CollisionH div 2 - py,
        speed)
    else:
      let dir = sim.fieldStep(px, py)
      if dir.found:
        step = unitStep(dir.toX - px, dir.toY - py, speed)
      else:
        step = (0, 0)
    if sim.zombies[i].stuckRotTicks > 0:
      dec sim.zombies[i].stuckRotTicks
      step = (-step.uy, step.ux)      ## a quarter turn clockwise on screen
    let moved = sim.stepZombieAxis(sim.zombies[i], step.ux, step.uy)
    if moved:
      sim.zombies[i].stuckTicks = 0
    else:
      inc sim.zombies[i].stuckTicks
      if sim.zombies[i].stuckTicks >= sim.config.zombieStuckTicks and
          sim.zombies[i].stuckRotTicks == 0:
        sim.zombies[i].stuckTicks = 0
        sim.zombies[i].stuckRotTicks = DefaultZombieRotTicks

proc pushZombiesOutOfWalls*(sim: var SimServer) =
  ## A turning diamond can sweep over a zombie hugging its edge (the field is
  ## built once, against the mask with the diamonds at spin frame 0, and cannot
  ## know about a later rotation). Standing inside stone would make a zombie
  ## unhittable from one side and unable to walk out, and it trips the sim
  ## guard, so the sweep displaces it to the nearest clear floor by the same
  ## deterministic expanding ring search the starter uses on cogs.
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    let
      px = sim.zombies[i].ux div MotionScale
      py = sim.zombies[i].uy div MotionScale
    if sim.zombieCanStand(px, py):
      continue
    var placed = false
    for r in 1 .. 64:
      for dy in -r .. r:
        for dx in -r .. r:
          if abs(dx) != r and abs(dy) != r:
            continue
          let
            nx = px + dx
            ny = py + dy
          if not sim.zombieCanStand(nx, ny):
            continue
          sim.zombies[i].ux = nx * MotionScale
          sim.zombies[i].uy = ny * MotionScale
          placed = true
          break
        if placed:
          break
      if placed:
        break
    if not placed:
      ## No standable floor within 64 px. Unreachable on the shipped board
      ## (the whole sweep displaces by at most a couple of pixels), but a
      ## zombie embedded in stone is a silent, self-perpetuating trap — retire
      ## it rather than leave it there, and never credit the kill.
      sim.zombies[i].alive = false

proc leaderZombie*(sim: SimServer): int =
  ## The index into `sim.zombies` of the live zombie with the smallest gate
  ## distance, ties to the lowest zombie id. -1 on an empty board.
  result = -1
  var best = high(int)
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    let d = sim.gateDistOf(sim.zombies[i])
    if d < best or (d == best and result >= 0 and
        sim.zombies[i].id < sim.zombies[result].id):
      best = d
      result = i

proc leaderGateDist*(sim: SimServer): int =
  let index = sim.leaderZombie()
  if index < 0: max(1, sim.spawnGateDist) else: sim.gateDistOf(sim.zombies[index])

proc pressurePct*(sim: SimServer): int =
  ## 0 % at the breach, 100 % at the gate — the number the viewer's horde
  ## pressure bar draws and the number the seat view reports.
  let span = max(1, sim.spawnGateDist)
  100 - clamp(100 * sim.leaderGateDist() div span, 0, 100)

proc recountAliveZombies*(sim: SimServer): int =
  for zombie in sim.zombies:
    if zombie.alive:
      inc result

proc pruneDeadZombies*(sim: var SimServer) =
  ## Drops the corpses once the frame that showed them has been emitted.
  ## Kept as a separate pass so `updatePressure` and the viewer both see the
  ## kill on the tick it happened.
  var kept: seq[Zombie] = @[]
  for zombie in sim.zombies:
    if zombie.alive:
      kept.add(zombie)
  sim.zombies = kept
