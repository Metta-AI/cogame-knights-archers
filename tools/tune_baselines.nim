## The `phalanx` grid harness.
##
## `BaselineParams` are a PARAMETER rather than three literals because they
## were chosen by this sweep, not guessed. It plays the whole four-seat,
## two-wave episode for every cell of a bounded matrix across several seeds,
## prints the table, and names the winner by banked team value
## (`kills + clearBonus * cleared`) — the same number the league scores.
##
##   nim c -d:release -o:/tmp/tune_baselines tools/tune_baselines.nim
##   /tmp/tune_baselines                # the sweep
##   /tmp/tune_baselines --check        # assert the shipped defaults still win
##
## `--check` is what CI runs: it re-plays the shipped defaults and the note's
## first guess and fails if the shipped cell is no longer at least as good, so
## a rules change that quietly ruins the baseline is caught here rather than on
## the ladder.

import
  std/[json, os, strformat, strutils],
  bitworld/spriteprotocol,
  ../src/kaz/[sim, control, directives, baselines]

const
  SweepSeeds = [679961, 4242, 77, 5150]
  CrowdPxGrid = [90, 120, 160]
  CrowdCountGrid = [2, 3, 4]
  GivePxGrid = [140, 220, 300]

proc episodeConfig(seed: int): GameConfig =
  var node = %*{
    "num_agents": 4, "minPlayers": 4, "maxTicks": 2304, "maxGames": 2,
    "turnTicks": 96, "turnBudgetMs": 7000, "attempt1Ms": 4500,
    "retryMs": 2000, "turnSpacingMs": 0, "wallClockBudgetSeconds": 690,
    "lobbyJoinTimeoutTicks": 1440, "startWaitTicks": 0, "gameOverTicks": 24,
    "mapPath": "arena", "fogOfWar": false, "fastMode": true,
    "showPlayerLabels": false, "lives": 1, "hitPoints": 1, "seed": seed,
    "roles": ["knight", "knight", "archer", "archer"],
    "tokens": ["t0", "t1", "t2", "t3"],
    "players": [{"name": "Knight A"}, {"name": "Knight B"},
                {"name": "Archer A"}, {"name": "Archer B"}],
    "slots": [{"team": "red"}, {"team": "red"},
              {"team": "red"}, {"team": "red"}]
  }
  result = defaultGameConfig()
  result.update($node)

proc play(
  kind: Baseline, seed: int, params: BaselineParams
): tuple[kills, cleared, value: int] =
  var sim = initSimServer(episodeConfig(seed))
  sim.gameEventLoggingEnabled = false
  for i in 0 ..< 4:
    discard sim.addPlayer("policy-" & $i, i, "", trusted = true)
  sim.startGame()
  var
    ctl = initControlState(sim)
    directives = newSeq[SquadDirective](sim.seatCount())
    have = newSeq[bool](sim.seatCount())
    prevInputs = newSeq[InputState](sim.players.len)
    waves = 0
    lastTurnKey = -1
  let turnTicks = max(1, sim.config.turnTicks)
  for _ in 0 ..< 40_000:
    var inputs = newSeq[InputState](sim.players.len)
    if sim.phase == Playing:
      ctl.observeHeroes(sim)
      let turnKey =
        sim.gameIndex * 1_000_000 + sim.gameTicksElapsed() div turnTicks
      if sim.gameTicksElapsed() mod turnTicks == 0 and turnKey != lastTurnKey:
        lastTurnKey = turnKey
        for seat in 0 ..< sim.seatCount():
          directives[seat] = scriptedDirective(
            ctl, sim, kind, sim.commandedCogs(seat), params)
          have[seat] = true
      for cogIndex in 0 ..< sim.players.len:
        let seat = sim.cogSeat(cogIndex)
        if not have[seat]:
          continue
        for order in directives[seat].orders:
          if order.cogIndex == cogIndex:
            inputs[cogIndex] =
              decodeInputMask(ctl.compileMask(sim, order, cogIndex))
    let before = sim.phase
    sim.step(inputs, prevInputs)
    prevInputs = inputs
    while prevInputs.len < sim.players.len:
      prevInputs.add(InputState())
    if before != GameOver and sim.phase == GameOver:
      inc waves
      sim.archiveWave()
      sim.gameIndex = waves
      if waves >= max(1, sim.config.maxGames):
        break
      lastTurnKey = -1
      sim.resetToLobby()
      sim.needsReregister = false
      for i in 0 ..< sim.seatCount():
        discard sim.addPlayer("policy-" & $i, i, "", trusted = true)
      have = newSeq[bool](sim.seatCount())
      sim.startGame()
      prevInputs = newSeq[InputState](sim.players.len)
  let value = sim.zombiesKilled + sim.config.clearBonus * sim.wavesCleared
  (sim.zombiesKilled, sim.wavesCleared, value)

proc totalFor(kind: Baseline, params: BaselineParams): int =
  for seed in SweepSeeds:
    result += play(kind, seed, params).value

when isMainModule:
  if paramCount() >= 1 and paramStr(1) == "--check":
    let
      shipped = totalFor(blPhalanx, DefaultBaselineParams)
      guess = totalFor(blPhalanx, BaselineParams(
        knightCrowdPx: 120, knightCrowdCount: 3, knightGivePx: 220))
      stand = totalFor(blStand, DefaultBaselineParams)
    echo &"phalanx(shipped)={shipped} phalanx(note's guess)={guess} stand={stand}"
    if shipped < guess:
      echo "::error::the shipped phalanx params are no longer the sweep's pick"
      quit(1)
    if shipped <= stand:
      echo "::error::phalanx must out-bank stand across the sweep seeds"
      quit(1)
    echo "tune_baselines --check: ok"
    quit(0)
  var
    best = -1
    bestParams = DefaultBaselineParams
  for crowdPx in CrowdPxGrid:
    for crowdCount in CrowdCountGrid:
      for give in GivePxGrid:
        let params = BaselineParams(
          knightCrowdPx: crowdPx, knightCrowdCount: crowdCount,
          knightGivePx: give)
        var
          total = 0
          row = ""
        for seed in SweepSeeds:
          let r = play(blPhalanx, seed, params)
          total += r.value
          row.add &"{r.kills}/{r.cleared} "
        echo &"crowdPx={crowdPx} count={crowdCount} give={give} " &
          &"value={total} [{row.strip()}]"
        if total > best:
          best = total
          bestParams = params
  echo &"BEST {bestParams} value={best}"
  echo &"stand value={totalFor(blStand, DefaultBaselineParams)}"
