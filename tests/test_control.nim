## The bounded-orders / legality assertion on the scripted baselines, and the
## head-to-head that pins `phalanx` above `stand`.

import
  std/[json, random, unicode],
  bitworld/spriteprotocol,
  kaz/[sim, control, directives, baselines],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

block everyEmittedDirectiveValidates:
  ## 500 pseudo-random world states x both baselines x all four seats: the
  ## emitted directive must validate against the reply schema, and every
  ## compiled mask must carry only legal bits.
  var
    sim = newHordeSim(maxTicks = 2304, maxGames = 1)
    ctl = initControlState(sim)
    rng = initRand(20260826)
  for trial in 0 ..< 500:
    # Scatter the heroes and the horde over the board.
    for i in 0 ..< sim.players.len:
      let spot = sim.nearestWalkable(
        rng.rand(MapWidth - 1), rng.rand(MapHeight - 1))
      sim.placePlayer(i, spot.x, spot.y)
      sim.players[i].alive = rng.rand(9) > 0
      sim.players[i].aimBrads = rng.rand(255)
      sim.players[i].fireCooldown = rng.rand(3)
    sim.zombies.setLen(0)
    for z in 0 ..< rng.rand(12):
      let spot = sim.nearestWalkable(
        rng.rand(MapWidth - 1), rng.rand(MapHeight - 1))
      sim.zombies.add Zombie(
        id: z, ux: spot.x * MotionScale, uy: spot.y * MotionScale,
        hp: 1 + rng.rand(2), lungeTarget: -1, alive: true)
    sim.aliveZombies = sim.recountAliveZombies()
    ctl.observeHeroes(sim)
    for kind in [blPhalanx, blStand]:
      for seat in 0 ..< sim.seatCount():
        let directive = scriptedDirective(ctl, sim, kind, sim.commandedCogs(seat))
        check(directive.note.runeLen <= MaxNoteRunes,
          "note over the cap: " & directive.note)
        check(directive.orders.len == 1,
          "a seat commands exactly one hero, got " & $directive.orders.len)
        for order in directive.orders:
          let why = sim.validateOrder(order, seat)
          check(why.len == 0, "trial " & $trial & " seat " & $seat & ": " & why)
          check(sim.isWalkable(order.targetX, order.targetY) or
                sim.canOccupy(order.targetX, order.targetY) or
                order.intent == intFallBack,
            "target is not on walkable ground")
          let mask = ctl.compileMask(sim, order, order.cogIndex)
          check(maskLegal(mask), "illegal mask bits " & $mask)
          check(mask == ctl.compileMask(sim, order, order.cogIndex),
            "compileMask is not a pure function of the state")
          if order.intent == intFallBack:
            check((mask and ButtonA) == 0, "fall_back must never set A")
          if sim.players[order.cogIndex].fireCooldown > 0:
            check((mask and ButtonA) == 0,
              "the trigger must never be set during a cooldown")

block aKnightNeverSwingsAtNothing:
  var
    sim = newHordeSim(maxTicks = 600, maxGames = 1)
    ctl = initControlState(sim)
  sim.zombies.setLen(0)
  sim.aliveZombies = 0
  ctl.observeHeroes(sim)
  for cogIndex in 0 ..< sim.players.len:
    let order = CogOrder(
      cogIndex: cogIndex, id: sim.cogAlias(cogIndex), intent: intHold,
      targetX: sim.players[cogIndex].x, targetY: sim.players[cogIndex].y)
    let mask = ctl.compileMask(sim, order, cogIndex)
    check((mask and ButtonA) == 0,
      "an empty board must never pull the trigger")

block anUnreachableTargetStillMovesEveryTick:
  var
    sim = newHordeSim(maxTicks = 600, maxGames = 1)
    ctl = initControlState(sim)
  let cogIndex = 0
  var moved = 0
  var prev = InputState()
  for t in 0 ..< 120:
    ctl.observeHeroes(sim)
    let order = CogOrder(
      cogIndex: cogIndex, id: sim.cogAlias(cogIndex), intent: intHold,
      targetX: 0, targetY: 0)      ## the map corner: inside the border wall
    let mask = ctl.compileMask(sim, order, cogIndex)
    if (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0:
      inc moved
    var inputs = newSeq[InputState](sim.players.len)
    inputs[cogIndex] = decodeInputMask(mask)
    var prevs = newSeq[InputState](sim.players.len)
    prevs[cogIndex] = prev
    sim.step(inputs, prevs)
    prev = inputs[cogIndex]
  check(moved >= 100,
    "a hero ordered to an unreachable target moved on only " & $moved &
      " of 120 ticks")

block phalanxOutKillsStand:
  var a = newHordeSim(maxTicks = 2304, maxGames = 2)
  let runA = a.runScripted(blPhalanx)
  var b = newHordeSim(maxTicks = 2304, maxGames = 2)
  let runB = b.runScripted(blStand)
  echo "phalanx: kills=", runA.teamKills, " cleared=", runA.wavesCleared,
    " endRules=", runA.endRules, " ticks=", runA.ticks
  echo "stand:   kills=", runB.teamKills, " cleared=", runB.wavesCleared,
    " endRules=", runB.endRules, " ticks=", runB.ticks
  check(runA.waves == 2, "phalanx must play both waves, played " & $runA.waves)
  check(runB.waves == 2, "stand must play both waves, played " & $runB.waves)
  check(runA.teamKills >= 20,
    "phalanx x4 must kill at least 20 zombies, killed " & $runA.teamKills)
  check(runA.teamKills > runB.teamKills,
    "phalanx (" & $runA.teamKills & ") must out-kill stand (" &
      $runB.teamKills & ")")

echo "test_control: ok"
