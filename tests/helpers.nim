## Shared test scaffolding: a four-seat horde episode driven entirely by the
## scripted control layer, with no server, no sockets and no LLM.
##
## Every test in this suite runs from the repo ROOT (assets resolve via
## `data/`), debug and release, per `ci.yml`'s test job.

import
  std/[json, unicode],
  bitworld/spriteprotocol,
  kaz/[sim, control, directives, baselines]

proc hordeConfig*(
  seats = 4,
  maxTicks = 600,
  maxGames = 2,
  seed = 679961,
  overrides: JsonNode = nil
): GameConfig =
  ## The shipped horde config, shrunk to a test-sized wave. Everything a
  ## variant sets is set here too, so a test exercises the same code path the
  ## league does.
  var node = %*{
    "num_agents": seats,
    "minPlayers": seats,
    "maxTicks": maxTicks,
    "maxGames": maxGames,
    "turnTicks": 96,
    "turnBudgetMs": 7000,
    "attempt1Ms": 4500,
    "retryMs": 2000,
    "turnSpacingMs": 0,
    "wallClockBudgetSeconds": 180,
    "lobbyJoinTimeoutTicks": 1440,
    "startWaitTicks": 0,
    "gameOverTicks": 24,
    "mapPath": "arena",
    "fogOfWar": false,
    "fastMode": true,
    "showPlayerLabels": false,
    "lives": 1,
    "hitPoints": 1,
    "seed": seed,
    "roles": ["knight", "knight", "archer", "archer"],
    "tokens": ["t0", "t1", "t2", "t3"],
    "players": [
      {"name": "Knight A"}, {"name": "Knight B"},
      {"name": "Archer A"}, {"name": "Archer B"}
    ],
    "slots": [
      {"team": "red"}, {"team": "red"}, {"team": "red"}, {"team": "red"}
    ]
  }
  if overrides != nil:
    for key, value in overrides:
      node[key] = value
  result = defaultGameConfig()
  result.update($node)

proc seatHeroes*(sim: var SimServer, seats: int) =
  ## Seats `seats` heroes with their anonymous aliases and starts the wave.
  for i in 0 ..< seats:
    discard sim.addPlayer("policy-" & $i, i, "", trusted = true)
  sim.startGame()

proc newLobbySim*(
  seats = 4,
  maxTicks = 600,
  maxGames = 2,
  seed = 679961,
  overrides: JsonNode = nil
): SimServer =
  ## A sim in the LOBBY, exactly as the server has it the moment the listener
  ## opens: no roster, no wave. The caller adds players (writing the join
  ## records a replay needs) and lets `sim.step` run the lobby countdown, which
  ## is the only path a replay can re-derive.
  initSimServer(hordeConfig(seats, maxTicks, maxGames, seed, overrides))

proc newHordeSim*(
  seats = 4,
  maxTicks = 600,
  maxGames = 2,
  seed = 679961,
  overrides: JsonNode = nil
): SimServer =
  result = initSimServer(
    hordeConfig(seats, maxTicks, maxGames, seed, overrides))
  result.seatHeroes(seats)

type
  ScriptedRun* = object
    ## What one scripted episode produced.
    ticks*: int
    waves*: int
    teamKills*: int
    wavesCleared*: int
    endRules*: seq[string]
    reason*: string
    masks*: seq[uint8]         ## every mask the control layer ever emitted

proc runScripted*(
  sim: var SimServer,
  kind: Baseline,
  maxSteps = 60_000,
  collectMasks = false
): ScriptedRun =
  ## Plays a whole episode on one scripted baseline, exactly as the server's
  ## tick loop does: the SIM's own phase machine drives the waves (the
  ## game-over hold, the lobby, the next `startGame`), one directive per seat
  ## every `turnTicks`, one compiled mask per hero every tick, and `sim.step`
  ## with the previous tick's inputs as `prev`. Following the sim's phase
  ## machine rather than forcing `resetToLobby` is what makes the recorded mask
  ## log re-simulate: a replay can only re-derive transitions the sim itself
  ## makes.
  var
    ctl = initControlState(sim)
    orders = newSeq[SquadDirective](sim.seatCount())
    have = newSeq[bool](sim.seatCount())
    prevInputs = newSeq[InputState](sim.players.len)
    waves = 0
    lastTurnKey = -1
  let turnTicks = max(1, sim.config.turnTicks)
  for step in 0 ..< maxSteps:
    if sim.phase == Lobby and sim.players.len == 0 and
        waves < max(1, sim.config.maxGames):
      for i in 0 ..< sim.seatCount():
        discard sim.addPlayer("policy-" & $i, i, "", trusted = true)
      have = newSeq[bool](sim.seatCount())
      prevInputs = newSeq[InputState](sim.players.len)
    var inputs = newSeq[InputState](sim.players.len)
    if sim.phase == Playing:
      ctl.observeHeroes(sim)
      let turnKey =
        sim.gameIndex * 1_000_000 + sim.gameTicksElapsed() div turnTicks
      if sim.gameTicksElapsed() mod turnTicks == 0 and turnKey != lastTurnKey:
        lastTurnKey = turnKey
        for seat in 0 ..< sim.seatCount():
          orders[seat] = scriptedDirective(
            ctl, sim, kind, sim.commandedCogs(seat))
          have[seat] = true
      for cogIndex in 0 ..< sim.players.len:
        let seat = sim.cogSeat(cogIndex)
        if not have[seat]:
          continue
        for order in orders[seat].orders:
          if order.cogIndex != cogIndex:
            continue
          let mask = ctl.compileMask(sim, order, cogIndex)
          if collectMasks:
            result.masks.add(mask)
          inputs[cogIndex] = decodeInputMask(mask)
    let phaseBefore = sim.phase
    sim.step(inputs, prevInputs)
    prevInputs = inputs
    while prevInputs.len < sim.players.len:
      prevInputs.add(InputState())
    if phaseBefore != GameOver and sim.phase == GameOver:
      inc waves
      sim.archiveWave()
      result.endRules.add(sim.endRule)
      sim.gameIndex = waves
      lastTurnKey = -1
      if waves >= max(1, sim.config.maxGames):
        break
  result.ticks = sim.tickCount
  result.waves = waves
  result.teamKills = sim.zombiesKilled
  result.wavesCleared = sim.wavesCleared
  result.reason =
    if sim.endReason.len > 0: sim.endReason else: ReasonComplete

proc maskLegal*(mask: uint8): bool =
  ## Up+Down and Left+Right are never set together, and C is never set —
  ## knights-archers places nothing C could throw.
  if (mask and ButtonUp) != 0 and (mask and ButtonDown) != 0:
    return false
  if (mask and ButtonLeft) != 0 and (mask and ButtonRight) != 0:
    return false
  if (mask and ButtonC) != 0:
    return false
  true

proc runeLenOf*(text: string): int =
  ## Rune length without importing std/unicode into every test.
  for _ in text.runes:
    inc result

proc validateOrder*(sim: SimServer, order: CogOrder, seat: int): string =
  ## "" when the order validates against the reply schema, else why not.
  if order.id != sim.cogAlias(seat):
    return "id " & order.id & " is not this seat's alias " & sim.cogAlias(seat)
  if order.targetX < 0 or order.targetX >= MapWidth or
      order.targetY < 0 or order.targetY >= MapHeight:
    return "target off the map"
  if order.say.runeLenOf() > MaxSayRunes:
    return "say over the cap"
  ""

