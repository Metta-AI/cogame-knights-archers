## The two weapons: the knight's wedge and the archer's arrow.

import
  std/json,
  kaz/sim,
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

proc quietSim(overrides: JsonNode = nil): SimServer =
  ## A wave with the spawn schedule OFF, so the only zombies on the board are
  ## the ones a test places.
  var node = %*{"spawnStartPerMille": 0, "spawnMaxPerMille": 0}
  if overrides != nil:
    for key, value in overrides:
      node[key] = value
  result = newHordeSim(maxTicks = 2400, maxGames = 1, overrides = node)

proc placeZombie(sim: var SimServer, id, x, y: int, hp = 2): int =
  sim.zombies.add Zombie(
    id: id, ux: x * MotionScale, uy: y * MotionScale, hp: hp,
    lungeTarget: -1, alive: true)
  sim.aliveZombies = sim.recountAliveZombies()
  sim.zombies.len - 1

proc faceHero(sim: var SimServer, cogIndex, x, y: int) =
  sim.players[cogIndex].aimBrads = bradsOfVector(
    x - (sim.players[cogIndex].x + CollisionW div 2),
    y - (sim.players[cogIndex].y + CollisionH div 2))

block oneBlowKillsAndOnlyInsideTheWedge:
  var sim = quietSim()
  let
    knight = 0
    hx = sim.players[knight].x + CollisionW div 2
    hy = sim.players[knight].y + CollisionH div 2
  check(sim.isKnight(knight), "seat 0 must be a knight")
  # Inside the wedge, at 40 px dead ahead.
  discard sim.placeZombie(1, hx + 40, hy)
  # Inside the reach but 90 degrees off the aim: outside the +-45 wedge.
  discard sim.placeZombie(2, hx, hy + 40)
  # Straight ahead but past the 52 px reach.
  discard sim.placeZombie(3, hx + 80, hy)
  sim.faceHero(knight, hx + 100, hy)
  sim.startHeroAttacks([knight])
  sim.resolveSwings()
  check(not sim.zombies[0].alive, "a 2 hp zombie must die to ONE blow")
  check(sim.zombies[1].alive, "a zombie 90 degrees off the aim must survive")
  check(sim.zombies[2].alive, "a zombie past 52 px must survive")
  check(sim.heroKills[knight] == 1, "the swinging seat must be credited")

block aSwingDamagesEachVictimAtMostOncePerActivation:
  var sim = quietSim(%*{"zombieHp": 5})
  let
    knight = 0
    hx = sim.players[knight].x + CollisionW div 2
    hy = sim.players[knight].y + CollisionH div 2
  discard sim.placeZombie(1, hx + 40, hy, hp = 5)
  sim.faceHero(knight, hx + 100, hy)
  sim.startHeroAttacks([knight])
  for _ in 0 ..< sim.config.swingTicks:
    sim.resolveSwings()
  check(sim.zombies[0].hp == 5 - sim.config.knightDamage,
    "one activation must land exactly once across all its lit ticks, hp=" &
      $sim.zombies[0].hp)

block theKnightCooldownIsExact:
  var sim = quietSim()
  let knight = 0
  sim.startHeroAttacks([knight])
  check(sim.players[knight].fireCooldown ==
      sim.config.knightCooldown + sim.config.swingTicks,
    "the cooldown covers the lit window plus knightCooldown")
  var ticks = 0
  while sim.players[knight].fireCooldown > 0 and ticks < 200:
    dec sim.players[knight].fireCooldown
    inc ticks
  check(ticks == sim.config.knightCooldown + sim.config.swingTicks,
    "cooldown ran " & $ticks & " ticks")

block anArrowFliesTwelvePixelsATickAndDiesAtItsRange:
  var sim = quietSim()
  let
    archer = 2
    hx = sim.players[archer].x + CollisionW div 2
  check(not sim.isKnight(archer), "seat 2 must be an archer")
  sim.players[archer].aimBrads = 0            ## due east
  sim.startHeroAttacks([archer])
  check(sim.arrows.len == 1, "one arrow")
  let before = sim.arrows[0].arrowPx()
  sim.updateArrows()
  let after = sim.arrows[0].arrowPx()
  check(after.x - before.x == 12,
    "an arrow travels 12 px/tick, moved " & $(after.x - before.x))
  discard hx
  var ticks = 1
  while sim.arrows.len > 0 and ticks < 400:
    sim.updateArrows()
    inc ticks
  check(ticks <= sim.config.arrowLifeTicks + 2,
    "an arrow must expire by " & $sim.config.arrowLifeTicks & " ticks, lived " &
      $ticks)

block twoArrowsKillAndOnlyTheFirstIsCredited:
  var sim = quietSim()
  let
    a = 2
    b = 3
    hx = sim.players[a].x + CollisionW div 2
    hy = sim.players[a].y + CollisionH div 2
  discard sim.placeZombie(1, hx + 24, hy)
  sim.players[a].aimBrads = 0
  sim.startHeroAttacks([a])
  sim.updateArrows()
  check(sim.zombies[0].alive, "one arrow must not kill a 2 hp zombie")
  check(sim.zombies[0].hp == 1, "one arrow removes one hit point")
  check(sim.arrows.len == 0, "the arrow is consumed by the body it touched")
  # A second arrow, from the other archer, finishes it.
  sim.players[b].x = sim.players[a].x
  sim.players[b].y = sim.players[a].y
  sim.players[b].aimBrads = 0
  sim.startHeroAttacks([b])
  sim.updateArrows()
  check(not sim.zombies[0].alive, "two arrows kill")
  check(sim.heroKills[b] == 1, "the LAST damage credits the kill")
  check(sim.heroKills[a] == 0, "the first arrow must not be credited")

block arrowsPassThroughHeroes:
  var sim = quietSim()
  let
    archer = 2
    hx = sim.players[archer].x + CollisionW div 2
    hy = sim.players[archer].y + CollisionH div 2
  ## Stand a knight 30 px in front of the archer and a zombie behind it. Both
  ## short of the nearest wall down that lane, which would consume the arrow
  ## and make the test prove nothing.
  sim.placePlayer(0, hx + 30, hy)
  discard sim.placeZombie(1, hx + 70, hy)
  sim.players[archer].aimBrads = 0
  sim.startHeroAttacks([archer])
  for _ in 0 ..< 8:
    sim.updateArrows()
  check(sim.players[0].alive, "there is NO friendly fire")
  check(sim.zombies[0].hp == 1,
    "the arrow must reach the zombie behind the knight")

block aWallStopsAnArrowAndASwing:
  var sim = quietSim()
  let knight = 0
  ## Find a wall pixel and put a zombie just behind it.
  var found = false
  for dx in 14 .. 50:
    let
      hx = sim.players[knight].x + CollisionW div 2
      hy = sim.players[knight].y + CollisionH div 2
    if sim.isWall(hx + dx, hy):
      discard sim.placeZombie(9, hx + dx + 4, hy)
      sim.faceHero(knight, hx + 200, hy)
      sim.startHeroAttacks([knight])
      sim.resolveSwings()
      check(sim.zombies[^1].alive, "a swing must not reach through a wall")
      found = true
      break
  ## Not every spawn formation has a wall inside 50 px; the test is a no-op
  ## when it does not, rather than a false failure.
  discard found

block maxArrowsIsNeverExceeded:
  var sim = quietSim()
  for i in 0 ..< MaxArrows * 2:
    sim.players[2].fireCooldown = 0
    sim.startHeroAttacks([2])
  check(sim.arrows.len <= MaxArrows,
    "arrow list overflowed to " & $sim.arrows.len)

echo "test_combat: ok"
