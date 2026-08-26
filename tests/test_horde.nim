## Sim unit tests for the horde: the spawn table, the gate flow field, the
## march, the lunge, the fatal touch, and seed determinism.

import
  std/[json, strutils],
  kaz/sim,
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

block spawnRowsAreRealFloor:
  var sim = newHordeSim(maxTicks = 240, maxGames = 1)
  check(sim.spawnRows.len >= MinSpawnRows,
    "spawnRows has " & $sim.spawnRows.len & " entries, want >= " &
      $MinSpawnRows)
  for y in sim.spawnRows:
    check(sim.canOccupy(sim.config.zombieSpawnX, y),
      "spawn row " & $y & " is not clear floor")
  check(sim.spawnGateDist > 0, "spawnGateDist must be positive")

block fieldIsFiniteAndDecreasesTowardTheGate:
  var sim = newHordeSim(maxTicks = 240, maxGames = 1)
  var reachable = 0
  for cell in 0 ..< sim.zombieField.len:
    if sim.zombieField[cell] >= 0:
      inc reachable
  check(reachable > 100, "only " & $reachable & " cells can reach the gate")
  # Walking one field step from the spawn column strictly decreases the
  # distance, all the way in.
  var
    x = sim.config.zombieSpawnX
    y = sim.spawnRows[sim.spawnRows.len div 2]
    last = sim.gateDistPx(x, y)
    steps = 0
  while last > 0 and steps < 4000:
    let dir = sim.fieldStep(x, y)
    check(dir.found, "flow field dead-ended at " & $x & "," & $y)
    x = dir.toX
    y = dir.toY
    let now = sim.gateDistPx(x, y)
    check(now < last, "field did not decrease: " & $last & " -> " & $now)
    last = now
    inc steps
  check(last == 0, "never reached the gate line in " & $steps & " steps")

block anUntouchedZombieCrossesTheBoardInAboutThirtySeconds:
  var sim = newHordeSim(
    seats = 4, maxTicks = 4000, maxGames = 1,
    overrides = %*{"spawnStartPerMille": 0, "spawnMaxPerMille": 0})
  # Park the heroes out of the way so nothing kills or lures the walker.
  for i in 0 ..< sim.players.len:
    sim.players[i].alive = false
  sim.spawnOneZombie()
  check(sim.zombies.len == 1, "expected exactly one zombie")
  var ticks = 0
  while sim.zombies.len > 0 and
      (sim.zombies[0].ux div MotionScale) > sim.config.gateX and ticks < 3000:
    sim.updateZombies()
    inc ticks
  # 1178 -> 40 at 1.5 px/tick is 759 ticks down a clear lane; the arena's
  # walls make the real path a little longer, so this is a generous band that
  # still fails a zombie that stalls or teleports.
  # 1178 -> 40 is 1138 px of straight line at 1.5 px/tick = 759 ticks; the
  # arena's walls make the real marched path about 20 % longer, and the band is
  # wide enough not to be a tuning tripwire but narrow enough to fail a zombie
  # that stalls (the pre-fix grid jammed one for 3000 ticks) or teleports.
  check(ticks >= 700 and ticks <= 1400,
    "unopposed crossing took " & $ticks & " ticks, want 700..1400")

block lungeRadiusIsExact:
  var sim = newHordeSim(maxTicks = 240, maxGames = 1)
  let hx = sim.players[0].x + CollisionW div 2
  let hy = sim.players[0].y + CollisionH div 2
  check(sim.nearestLungeHero(hx + sim.config.zombieLungePx - 1, hy) == 0,
    "a hero 89 px away must be lunged at")
  check(sim.nearestLungeHero(hx + sim.config.zombieLungePx + 1, hy) < 0,
    "a hero 91 px away must not be lunged at")

block contactRadiusIsExact:
  for offset in [DefaultZombieReach - 1, DefaultZombieReach + 1]:
    var sim = newHordeSim(
      maxTicks = 240, maxGames = 1,
      overrides = %*{"spawnStartPerMille": 0, "spawnMaxPerMille": 0})
    let
      hx = sim.players[0].x + CollisionW div 2
      hy = sim.players[0].y + CollisionH div 2
    sim.zombies.add Zombie(
      id: 0, ux: (hx + offset) * MotionScale, uy: hy * MotionScale,
      hp: 2, lungeTarget: -1, alive: true)
    sim.aliveZombies = 1
    sim.resolveContacts()
    if offset < DefaultZombieReach:
      check(not sim.players[0].alive, "a hero at 25 px must die this tick")
      check(sim.waveCasualty == 0, "the casualty seat must be recorded")
    else:
      check(sim.players[0].alive, "a hero at 27 px must not die")

block spawnAccumulatorIntegratesTheRamp:
  var sim = newHordeSim(
    maxTicks = 2304, maxGames = 1,
    overrides = %*{"spawnCapAlive": 64})
  var expected = 0
  for t in 0 ..< 2304:
    expected += sim.spawnRatePerMille(t)
  let want = expected div 1000
  # Drive the accumulator alone, with nothing killing and nothing capping.
  var spawned = 0
  for t in 0 ..< 2304:
    sim.spawnAcc += sim.spawnRatePerMille(t)
    while sim.spawnAcc >= 1000:
      sim.spawnAcc -= 1000
      inc spawned
  check(abs(spawned - want) <= 1,
    "ramp integrated to " & $spawned & ", want " & $want)
  check(want >= 70 and want <= 90,
    "a full wave should spawn ~79 zombies, got " & $want)

block theCapDefersPressureRatherThanLosingIt:
  var sim = newHordeSim(
    maxTicks = 2304, maxGames = 1,
    overrides = %*{"spawnStartPerMille": 500, "spawnMaxPerMille": 500,
                   "spawnCapAlive": 4})
  for _ in 0 ..< 200:
    sim.spawnZombies()
  check(sim.aliveZombies <= 4,
    "the cap must hold the board at 4, got " & $sim.aliveZombies)
  check(sim.spawnAcc >= 0, "the accumulator must never go negative")

block theSameSeedProducesTheSameHorde:
  proc stream(seed: int): string =
    var sim = newHordeSim(maxTicks = 600, maxGames = 1, seed = seed)
    for i in 0 ..< sim.players.len:
      sim.players[i].alive = false
    for _ in 0 ..< 600:
      sim.spawnZombies()
      sim.updateZombies()
    for zombie in sim.zombies:
      result.add($zombie.id & ":" & $zombie.ux & "," & $zombie.uy & ";")
  check(stream(679961) == stream(679961),
    "two runs from one seed must be byte-identical")
  check(stream(679961) != stream(11111),
    "two runs from different seeds must differ")

block noHashedFieldTakesATargetWidthConstant:
  ## The native/wasm gate failed at tick 1 with nothing else wrong because a
  ## HASHED field was initialised to `low(int) div 2`, which is -2^31 on the
  ## wasm32 viewer and -2^63 on the native server. A sentinel that reaches
  ## gameHash has to be a fixed literal.
  var hashed: seq[string]
  let stateSource = readFile("src/kaz/sim_state.nim")
  let hashBody = stateSource[stateSource.find("proc gameHash*") .. ^1]
  for line in hashBody.splitLines():
    if line.contains("proc ") and not line.contains("proc gameHash*"):
      break
    let at = line.find("sim.")
    if at < 0:
      continue
    var name = ""
    for ch in line[at + 4 .. ^1]:
      if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
        name.add(ch)
      else:
        break
    if name.len > 0 and name notin hashed:
      hashed.add(name)
  check(hashed.len > 20,
    "the hashed-field scan found only " & $hashed.len & " fields")
  for path in ["src/kaz/horde.nim", "src/kaz/sim.nim", "src/kaz/arrows.nim",
               "src/kaz/melee.nim", "src/kaz/sim_state.nim"]:
    for line in readFile(path).splitLines():
      if not (line.contains("low(int)") or line.contains("high(int)")):
        continue
      if not line.contains("="):
        continue
      let target = line.split('=')[0]
      if not target.contains("sim."):
        continue
      for field in hashed:
        check(not target.contains("." & field),
          path & ": the HASHED field " & field & " is assigned a " &
            "target-width constant:\n  " & line.strip())

block theNewSimModulesAreIntegerOnly:
  ## Nim's `int` is 32 bits under --cpu:wasm32 and a float would additionally
  ## depend on whichever libm the build container shipped, so the new hashed
  ## modules carry no floating point and no libm call at all.
  ##
  ## design.md:830-832 also names sim.nim, sim_types.nim and sim_state.nim.
  ## Those three are deliberately NOT swept and cannot be (r1 review N23):
  ## sim_types owns `aimVector`/`bradsOfVector`, the float trig the RENDER path
  ## reads and the sim never calls; sim_state's float coordinates are event
  ## payloads (`emitEvent(x = float(...))`) that reach the tier-2 JSON stream,
  ## not the hash; sim.nim carries the inherited paintball render helpers. The
  ## rule this block enforces is the one that matters -- no float on a HASHED
  ## code path -- and control.nim is swept too even though it is not hashed,
  ## because it is the module the horde's steering shares arithmetic with.
  for path in ["src/kaz/horde.nim", "src/kaz/arrows.nim", "src/kaz/melee.nim",
               "src/kaz/control.nim"]:
    var i = 0
    for line in readFile(path).splitLines():
      inc i
      let code = (if line.find("##") >= 0: line[0 ..< line.find("##")] else: line)
      if code.strip().startsWith("#"):
        continue
      for banned in ["float", "sqrt", "hypot", "arctan", " sin(", " cos(",
                     " tan(", "aimVector"]:
        check(not code.contains(banned),
          path & ":" & $i & " uses " & banned &
            ", but this module is INTEGER ONLY:\n  " & code.strip())

echo "test_horde: ok"
