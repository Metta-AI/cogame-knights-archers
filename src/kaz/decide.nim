## The decision layer: the per-turn loop that asks all four heroes what they
## do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (96 ticks = 4.0 s of sim time), 24 turns
## per wave, 48 per episode. At each turn the server builds ALL FOUR seats'
## request bodies and issues them as ONE PARALLEL BATCH — knights-archers is a
## simultaneous-decision game, so querying seats one after another would
## quadruple the wall clock for no gain. One call per seat per turn; an episode
## is at most 4 x 48 = 192 calls, at most 4 in flight.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat plays
## the `phalanx` scripted directive for that turn and a `fallback` record names
## the cause. No failure mode leaves a hero unactuated: the control layer
## always has a directive — this turn's, else last turn's, else `phalanx`'s.
##
## THE RATE FLOOR. The Bedrock sidecar caps 30 requests/minute PER EPISODE, and
## four seats per turn would blow straight through it at any fast cadence. A
## `turnSpacingMs` = 9000 wall-clock floor between the STARTS of consecutive
## batches holds the episode at 4 x 60 / 9 = 26.7 req/min.

import
  std/[json, monotimes, os, strutils, times],
  curly,
  sim, control, directives, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `phalanx`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    directives*: seq[SquadDirective]
    haveDirective*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState(sim)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  result.directives = newSeq[SquadDirective](sim.seatCount())
  result.haveDirective = newSeq[bool](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blPhalanx
    result.seats[i].label = "phalanx"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc seatViewJson*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex, turnsPerGame: int
): string =
  ## Everything this seat may legitimately know, in map pixels, rounded to
  ## integers. The board is FULLY OBSERVABLE (`fogOfWar: false` in every
  ## shipped variant): PettingZoo's KAZ is, this is a cooperative game where
  ## hiding the board from partners adds a puzzle the idea never asks for, and
  ## the horde pressure bar is a public readout.
  ##
  ## HIDDEN, deliberately: the other seats' directives FOR THE TURN BEING
  ## DECIDED (all four decide simultaneously, which is exactly why `say` and
  ## `note` matter), every seat's PLAYER_PROMPT, the identity of any policy
  ## (real names never reach a seat), the episode seed, and the RNG state and
  ## therefore every future spawn row and spawn time.
  let
    cogIndex = seat
    hero =
      if cogIndex >= 0 and cogIndex < sim.players.len: sim.players[cogIndex]
      else: Player()
    hx = hero.x + CollisionW div 2
    hy = hero.y + CollisionH div 2
    role = sim.roleForSeat(seat)
    knight = role == RoleKnight
    gate = gateCentre(sim)
    played = sim.gameTicksElapsed() div TargetFps
    total = (if sim.config.maxTicks > 0: sim.config.maxTicks div TargetFps
             else: 0)
    ranked = rankedZombies(sim)
    leaderDist = sim.leaderGateDist()

  var zombies = newJArray()
  for i, slot in ranked:
    if i >= sim.config.spawnCapAlive:
      break
    let (zx, zy) = sim.zombies[slot].zombiePx()
    zombies.add(%*{
      "id": sim.zombies[slot].id,
      "pos": [zx, zy],
      "hp": max(0, sim.zombies[slot].hp),
      "gate_px": sim.gateDistOf(sim.zombies[slot]),
      "speed_px_s": sim.config.zombieSpeed * TargetFps div MotionScale,
      "lunging_at": (
        if sim.zombies[slot].lungeTarget >= 0:
          %sim.cogAlias(sim.zombies[slot].lungeTarget)
        else: newJNull())
    })

  var squad = newJArray()
  for other in 0 ..< sim.players.len:
    if other == cogIndex:
      continue
    var
      lastNote = newJNull()
      lastSay = newJNull()
      lastIntent = newJNull()
    ## LAST turn's note and say, never this turn's: `engine.directives[other]`
    ## is only overwritten at the top of a turn AFTER every seat's reply has
    ## been installed, so during a turn it still holds the previous one for
    ## every seat but this one — and this seat's own is reported separately as
    ## `your_last_directive`.
    if other < engine.haveDirective.len and engine.haveDirective[other]:
      lastNote = %engine.directives[other].note
      for order in engine.directives[other].orders:
        if order.cogIndex == other:
          lastIntent = %($order.intent)
          lastSay = %order.say
    squad.add(%*{
      "id": sim.cogAlias(other),
      "role": sim.roleOf(other),
      "pos": [sim.players[other].x + CollisionW div 2,
              sim.players[other].y + CollisionH div 2],
      "alive": sim.players[other].alive,
      "kills": (if other < sim.heroKills.len: sim.heroKills[other] else: 0),
      "last_intent": lastIntent,
      "last_note": lastNote,
      "last_say": lastSay
    })

  var node = %*{
    "wave": sim.gameIndex + 1,
    "of": max(1, sim.config.maxGames),
    "turn": turnIndex,
    "turns": turnsPerGame,
    "clock": {"played_s": played, "left_s": max(0, total - played)},
    "you": {
      "id": sim.cogAlias(cogIndex),
      "role": role,
      "alive": hero.alive,
      "pos": [hx, hy],
      "aim": hero.aimBrads,
      "kills": (if cogIndex < sim.heroKills.len: sim.heroKills[cogIndex] else: 0),
      "reach_px": (if knight: sim.config.knightReach else: sim.config.arrowRange),
      "cooldown_ticks": sim.heroCooldownTicks(cogIndex),
      "speed_px_s":
        sim.config.maxSpeed * sim.heroSpeedPct(cogIndex) div 100 *
          TargetFps div MotionScale,
      "ready": sim.heroWeaponReady(cogIndex)
    },
    "gate": {
      "line_x": sim.config.gateX,
      "centre": [gate.x, gate.y],
      "breach_ends_wave": true
    },
    "breach": {"line_x": sim.config.zombieSpawnX},
    "pressure": {
      "alive": sim.aliveZombies,
      "leader_gate_px": leaderDist,
      "leader_pct": sim.pressurePct(),
      "spawned": sim.zombiesSpawned,
      "killed": sim.waveKillsSoFar,
      "closest_call_px": sim.minGateDist,
      "spawn_rate_per_s":
        sim.spawnRatePerMille(sim.gameTicksElapsed()) * TargetFps
    },
    "zombies": zombies,
    "squad": squad,
    "score": {
      "team": sim.teamScorePermille().float / 1000.0,
      "team_kills": sim.zombiesKilled,
      "waves_cleared": sim.wavesCleared,
      "round_target": sim.config.roundTarget,
      "clear_bonus": sim.config.clearBonus
    }
  }
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    node["your_last_directive"] = %engine.directives[seat].note
  else:
    node["your_last_directive"] = newJNull()
  $node

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(
  wave, turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "wave": wave,
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  seat: int, alias, role, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "role": role,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end (design §Record
  ## vocabulary, docs/PROTOCOL.md §The replay). It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.heroResultsJson() & "}"

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc scriptedFor(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): SquadDirective =
  scriptedDirective(engine.ctl, sim, kind, sim.commandedCogs(seat))

proc phalanxFor*(
  engine: DecisionEngine, sim: SimServer, cogs: seq[int]
): SquadDirective =
  ## The published `phalanx` directive for an arbitrary hero set — the
  ## per-turn fallback, the driver of a no-show seat, and the default.
  scriptedDirective(engine.ctl, sim, blPhalanx, cogs)

proc repairMissingOrders*(
  engine: DecisionEngine, sim: SimServer, seat: int,
  directive: var SquadDirective
) =
  ## Design §Reply schema, the `cogs` row: "an empty or missing array keeps
  ## last turn's directive, else `phalanx`'s". The parser fills an unnamed
  ## entry with `intercept` at the gate centre so no hero is ever left
  ## unactuated; that default is a floor, not the rule.
  var previous: seq[CogOrder]
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    previous = engine.directives[seat].orders
  var
    phalanx: SquadDirective
    builtPhalanx = false
  for order in directive.orders.mitems:
    if order.fromReply:
      continue
    var repaired = false
    for old in previous:
      if old.cogIndex == order.cogIndex:
        order = old                  ## last turn's directive for this cog
        repaired = true
        break
    if repaired:
      continue
    if not builtPhalanx:
      phalanx = engine.phalanxFor(sim, sim.commandedCogs(seat))
      builtPhalanx = true
    for fallback in phalanx.orders:
      if fallback.cogIndex == order.cogIndex:
        order = fallback             ## else phalanx's
        break

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex, turnsPerGame: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's directive. Returns the
  ## replay chat records this turn produced. Never raises: every failure path
  ## ends in a legal directive.
  let
    wave = sim.gameIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a daily-token 429 on turn k says nothing
  ## about turn k+1 (the sidecar's window may have rolled), so the flag is
  ## cleared here and only suppresses this turn's retry.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  # If two more full turns would not fit inside the engine's own wall-clock
  # stop, switch the LLM off for the rest of the episode and finish on the
  # scripted layer (microseconds per turn), so the episode ends
  # complete/full_time instead of deadline.
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "knights-archers: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens (`no_credentials`, `budget_guard`). Recording it is
      # what makes the two countable: without this an LLM seat with no key
      # reported llmTurns 0 AND fallbackTurns 0, and replay_summary.py's
      # `fallbacks` was 0 for an episode in which nothing but fallbacks
      # happened. A seat that registered as SCRIPTED is not a fallback and
      # gets no record (which is why certification's two baseline seats write
      # none).
      var directive = engine.phalanxFor(sim, sim.commandedCogs(seat))
      directive.source = dsFallback
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(wave, turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing phalanx"))
      echo "knights-archers llm: seat ", seat, " falling back to phalanx (", cause,
        ") on turn ", turnIndex
    else:
      var directive = engine.scriptedFor(
        sim, seat, engine.seats[seat].baseline)
      directive.source = dsScripted
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE, and two seats at
  # a fast turn sit right on it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at <= 24 req/min. The cert
  # fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          wave, turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = engine.seatViewJson(sim, seat, turnIndex, turnsPerGame)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', with one " &
          "\"cogs\" entry per cog you command.")
      let request = engine.client.requestFor(
        systemPromptFor(sim.roleForSeat(seat)),
        userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — and a config that is not a whole
    # number of seconds is therefore not the deadline it claims to be. 0.1.2
    # shipped `attempt1Ms: 4500` and really ran with 4 s against a sidecar
    # whose median call measured 4618 ms; every successful LLM directive in
    # that release reported a latency of 3999–4001 ms, i.e. it was the
    # deadline answering, not the model. sim_config now REJECTS a sub-second
    # value, so the floor below is an identity: 6000 -> 6 s, 3000 -> 3 s,
    # worst case 9 s inside the 10 s turnBudgetMs cap.
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is
    ## WHOLE SECONDS. This CEILS rather than floors: the design pins
    ## `attempt1Ms: 4500`, and flooring would have run it at 4 s against a
    ## sidecar whose median call measures ~4.6 s, so every "successful" LLM
    ## directive would have been the deadline answering rather than the model
    ## (paintball 0.1.2 shipped exactly that bug). Ceiling 4500 -> 5 s and
    ## 2000 -> 2 s keeps the worst case at 7 s, exactly the turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, (deadlineMs + 999) div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        let commanded = sim.commandedCogs(seat)
        var ids: seq[string]
        for cogIndex in commanded:
          ids.add(sim.cogAlias(cogIndex))
        let gate = gateCentre(sim)
        var directive = parseSquadDirective(
          extractJsonObject(text), ids, commanded,
          gate.x, gate.y, MapWidth - 1, MapHeight - 1)
        directive.source = dsLlm
        directive.latencyMs = latency
        engine.repairMissingOrders(sim, seat, directive)
        engine.directives[seat] = directive
        engine.haveDirective[seat] = true
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is. Reporting a 429 as
          ## `parse_error` is what made the hosted log unreadable: 205
          ## "falling back (parse_error)" lines for an episode whose only
          ## fault was a daily-token cap.
          cause = "throttled"
        result.add(fallbackRecord(
          wave, turnIndex, seat, attempt + 1, cause, error.msg))
        echo "knights-archers llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land. Bounded, and recorded as
      # a `fallback` with cause `throttled` by the block below.
      echo "knights-archers llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays phalanx for this turn ---------------------
  for seat in open:
    var directive = engine.phalanxFor(sim, sim.commandedCogs(seat))
    directive.source = dsFallback
    engine.directives[seat] = directive
    engine.haveDirective[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(wave, turnIndex, seat, 2, cause,
      "seat fell back to the phalanx directive"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "knights-archers llm: seat ", seat, " falling back to phalanx (", cause,
      ") on turn ", turnIndex
