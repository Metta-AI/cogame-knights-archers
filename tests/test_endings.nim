## End conditions: the three `results.reason` values, the six `endRule`
## values, and the order they are evaluated in.

import
  std/json,
  bitworld/spriteprotocol,
  kaz/[sim, baselines],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

proc quietSim(maxTicks = 2400, maxGames = 1): SimServer =
  newHordeSim(
    maxTicks = maxTicks, maxGames = maxGames,
    overrides = %*{"spawnStartPerMille": 0, "spawnMaxPerMille": 0})

proc idle(sim: var SimServer, ticks: int) =
  ## Steps with all-zero inputs and STOPS at the game-over frame: past it the
  ## sim's own hold timer returns to the lobby and the phase under test is
  ## gone.
  var prev = newSeq[InputState](sim.players.len)
  for _ in 0 ..< ticks:
    let inputs = newSeq[InputState](sim.players.len)
    sim.step(inputs, prev)
    prev = inputs
    if sim.phase == GameOver:
      return

block aZombieAtTheGateLineEndsTheWaveOnThatTick:
  var sim = quietSim()
  let gate = sim.config.gateX
  sim.zombies.add Zombie(
    id: 1, ux: (gate + 3) * MotionScale,
    uy: (MapHeight div 2) * MotionScale, hp: 2, lungeTarget: -1, alive: true)
  sim.aliveZombies = 1
  ## One step short of the line: still playing.
  sim.checkHordeEnd()
  check(sim.phase == Playing, "a zombie at x > gateX must not end the wave")
  sim.zombies[0].ux = gate * MotionScale
  sim.checkHordeEnd()
  check(sim.phase == GameOver, "a zombie at x == gateX ends the wave")
  check(sim.endRule == EndRuleBreach, "endRule must be breach")
  check(sim.breachZombie == 1, "the breaching zombie's id must be recorded")
  check(sim.wavesCleared == 0, "a breach banks NO clear bonus")

block aTouchedHeroEndsTheWaveCasualty:
  var sim = quietSim()
  sim.waveCasualty = 2
  sim.checkHordeEnd()
  check(sim.phase == GameOver, "a casualty ends the wave")
  check(sim.endRule == EndRuleCasualty, "endRule must be casualty")
  check(sim.wavesCleared == 0, "a casualty banks NO clear bonus")

block aTickWithBothIsABreach:
  var sim = quietSim()
  sim.waveCasualty = 0
  sim.zombies.add Zombie(
    id: 7, ux: (sim.config.gateX - 5) * MotionScale,
    uy: (MapHeight div 2) * MotionScale, hp: 2, lungeTarget: -1, alive: true)
  sim.aliveZombies = 1
  sim.checkHordeEnd()
  check(sim.endRule == EndRuleBreach,
    "a tick in which BOTH happen is a breach, got " & sim.endRule)

block afullTimeWaveClears:
  var sim = quietSim(maxTicks = 240, maxGames = 1)
  sim.idle(300)
  check(sim.phase == GameOver, "the wave must end at maxTicks")
  check(sim.endRule == EndRuleFullTime, "endRule must be full_time")
  check(sim.wavesCleared == 1, "a full-time wave increments wavesCleared")

block waveLogRecordsExactlyOneEntryPerWavePlayed:
  var sim = newHordeSim(
    maxTicks = 240, maxGames = 2,
    overrides = %*{"spawnStartPerMille": 0, "spawnMaxPerMille": 0})
  let run = sim.runScripted(blStand)
  check(run.waves == 2, "both waves must play, played " & $run.waves)
  check(sim.waveTicksLog.len == 2,
    "waveLog has " & $sim.waveTicksLog.len & " entries, want 2")
  check(sim.waveEndRuleLog.len == 2 and sim.waveKillsLog.len == 2 and
    sim.waveClosestLog.len == 2, "every wave array must have one row per wave")
  let results = parseJson(sim.heroResultsJson())
  check(results["waveTicks"].len == 2, "results.waveTicks must have 2 rows")
  check(results["games"].getInt() == 2, "results.games must be 2")

block theEnumsAreClosed:
  var sim = quietSim()
  let results = parseJson(sim.heroResultsJson())
  check(results["reason"].getStr() in
    [ReasonComplete, ReasonDeadline, ReasonFault],
    "reason is outside the declared enum")
  check(results["endRule"].getStr() in
    [EndRuleFullTime, EndRuleBreach, EndRuleCasualty, EndRuleWallClock,
     EndRuleSimFault, EndRuleHostError],
    "endRule is outside the declared enum")

block theWallClockStopBanksTheWaveInProgress:
  ## The engine stop the server applies: reason `deadline`, rule `wall_clock`,
  ## the in-progress wave's kills banked, NO clear bonus.
  var sim = quietSim(maxTicks = 2400, maxGames = 2)
  sim.heroKills = @[5, 4, 3, 2]
  sim.zombiesKilled = 14
  sim.waveKillsSoFar = 14
  sim.endReason = ReasonDeadline
  sim.endRule = EndRuleWallClock
  sim.finishGame(Red, isDraw = false)
  sim.archiveWave()
  let results = parseJson(sim.heroResultsJson())
  check(results["reason"].getStr() == ReasonDeadline, "reason must be deadline")
  check(results["endRule"].getStr() == EndRuleWallClock,
    "endRule must be wall_clock")
  check(results["teamKills"].getInt() == 14, "the kills must be banked")
  check(results["wavesCleared"].getInt() == 0, "no clear bonus on a deadline")

block aTrippedInvariantIsASimFault:
  var sim = quietSim()
  ## A kill credited to nobody: the guard's sum(kills[s]) == zombiesKilled row.
  sim.zombiesKilled = 3
  var raised = false
  try:
    sim.checkHordeInvariants()
  except SimGuardError:
    raised = true
  check(raised, "the sim guard must trip on a credit mismatch")
  sim.endReason = ReasonFault
  sim.endRule = EndRuleSimFault
  let results = parseJson(sim.heroResultsJson())
  check(results["reason"].getStr() == ReasonFault, "reason must be fault")
  for value in results["win"]:
    check(not value.getBool(), "a fault wins nothing")

echo "test_endings: ok"
