## The game sends one private observation per seat before waiting for actions.

import std/json
import kaz/[sim, decide, control, directives]
import ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

proc llmWorld(): SimServer =
  result = newHordeSim(maxTicks = 2304, maxGames = 1)
  result.gameEventLoggingEnabled = false
  result.config.turnSpacingMs = 0

proc seatEveryoneLlm(engine: var DecisionEngine) =
  for seat in 0 ..< engine.seats.len:
    engine.seats[seat].isLlm = true
    engine.seats[seat].registered = true
    engine.seats[seat].label = "prompt"

proc validReply(request: JsonNode): string =
  $ %*{
    "type": "action",
    "protocol": "kaz.player.v2",
    "id": request["id"],
    "source": "llm",
    "action": {
      "note": "hold the line",
      "cogs": [{
        "id": request["view"]["you"]["id"],
        "intent": "screen",
        "target": [560, 240],
        "say": "line"
      }]
    }
  }

block allFourSeatsSeeOnePreActionState:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var batches: seq[seq[JsonNode]]
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    batches.add(requests)
    result = newSeq[string](requests.len)
    for position, request in requests:
      result[position] = validReply(request)
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(batches.len == 1, "one batch for four simultaneous seats")
  check(batches[0].len == 4, "the batch must contain four private views")
  for seat, request in batches[0]:
    check(request["slot"].getInt() == seat, "slot order is stable")
    check(request["view"]["you"]["id"].getStr() == world.cogAlias(seat),
      "each seat sees its own alias")
    check(request["view"]["turn"].getInt() == 0,
      "all seats see the same pre-action turn")
    check(engine.haveDirective[seat], "seat has an accepted directive")
    check(engine.directives[seat].source == dsLlm,
      "accepted player action is model-sourced")
    check(engine.directives[seat].orders[0].cogIndex == seat,
      "an action commands only its own hero")
  for record in records:
    check(parseJson(record){"k"}.getStr() != "fallback",
      "valid actions produce no fallback")

block invalidActionsRetryExactlyOnce:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var attempts = 0
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    inc attempts
    result = newSeq[string](requests.len)
    for position, request in requests:
      result[position] = if attempts == 1: "not json" else: validReply(request)
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(attempts == 2, "one retry after unusable replies")
  var errors = 0
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      check(node["attempt"].getInt() == 1, "only first attempts fail")
      if node["cause"].getStr() == "parse_error":
        inc errors
  check(errors == 4, "each unusable action records one parse error")
  for seat in 0 ..< world.seatCount():
    check(engine.directives[seat].source == dsLlm,
      "the second accepted action drives each hero")

block missingActionsHaveOneSharedDeadlineAndFallback:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var deadlines: seq[int]
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    deadlines.add(timeoutMs)
    check(requests.len == 4, "each attempt sends all four views together")
    newSeq[string](requests.len)
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(deadlines == @[5000, 2000], "the two batch deadlines are bounded")
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat], "a missing action leaves no hero idle")
    check(engine.directives[seat].source == dsFallback,
      "missing player actions use the phalanx fallback")
  var timeouts = 0
  for record in records:
    if parseJson(record){"cause"}.getStr() == "timeout":
      inc timeouts
  check(timeouts == 8, "both attempts name every seat timeout")

block aCredentialFreePlayerReportsFallbackImmediately:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var batches = 0
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    inc batches
    result = newSeq[string](requests.len)
    for position, request in requests:
      result[position] = $ %*{
        "type": "action", "protocol": "kaz.player.v2",
        "id": request["id"], "source": "fallback",
        "cause": "no_credentials"
      }
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(batches == 1, "explicit no-credential fallback does not retry")
  var noCredentials = 0
  for record in records:
    if parseJson(record){"cause"}.getStr() == "no_credentials":
      inc noCredentials
  check(noCredentials == 4, "each credential-free seat records a fallback")
  for seat in 0 ..< world.seatCount():
    check(engine.directives[seat].source == dsFallback,
      "credential-free seats play phalanx")

block theBudgetGuardSettlesEarlyRatherThanOverrunning:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  let elapsed = world.config.wallClockBudgetSeconds -
    (world.config.turnBudgetMs div 1000)
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    raise newException(ValueError, "budget guard must avoid the exchange")
  let records = engine.turn(world, 20, 24, elapsed, exchange)
  check(engine.llmOff, "the budget guard must latch")
  var guarded = false
  for record in records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      guarded = true
  check(guarded, "the guard must name the turn it fired on")
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat], "budget guard leaves no hero idle")

block theShippedVariantsPaceThemselvesInsideTheBudget:
  let manifest = parseJson(readFile("coworld_manifest_template.json"))
  for variant in manifest["variants"]:
    let
      cfg = variant["game_config"]
      id = variant["id"].getStr()
      seats = cfg["num_agents"].getInt()
      spacing = cfg["turnSpacingMs"].getInt()
      budget = cfg["turnBudgetMs"].getInt()
      stop = cfg["wallClockBudgetSeconds"].getInt()
    let perMinute = seats * 60_000 div max(1, spacing)
    check(perMinute <= 30, id & ": too many model calls per minute")
    check(spacing > budget, id & ": spacing must exceed the turn budget")
    check(cfg["attempt1Ms"].getInt() + cfg["retryMs"].getInt() <= budget,
      id & ": both deadlines must fit inside one turn budget")
    let turns = max(1, cfg["maxTicks"].getInt() div
      cfg["turnTicks"].getInt()) * max(1, cfg["maxGames"].getInt())
    let worst = turns * spacing div 1000 +
      cfg["lobbyJoinTimeoutTicks"].getInt() div TargetFps + 60 + 20
    check(worst <= stop, id & ": episode can overrun the engine stop")
    check(stop <= 720, id & ": engine stop exceeds 60% of platform timeout")

block anUnregisteredSeatStillPlaysPhalanx:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.ctl.observeHeroes(world)
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    raise newException(ValueError, "scripted seats must not use the exchange")
  discard engine.turn(world, 0, 24, 0, exchange)
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat], "unregistered seat has a directive")
    check(engine.directives[seat].source == dsScripted,
      "unregistered seat plays the published default")

echo "test_engine: ok"
