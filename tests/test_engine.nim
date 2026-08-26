## The turn loop, against a FAKE Bedrock sidecar on localhost.
##
## The one thing this file exists to prove is that all four seats' calls go out
## in ONE PARALLEL BATCH per turn. Knights-archers is a simultaneous-decision
## game: querying seats one after another would quadruple the wall clock for
## nothing, and at four seats x 48 turns it would also blow the episode budget.
## The fake records every request's in-flight window and the test asserts all
## four intersect.

import
  std/[json, os, osproc, streams, strutils, times],
  kaz/[sim, decide, control, directives],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

type FakeSidecar = object
  process: Process
  port: int
  logPath: string

proc startFake(hangSeconds = 0.0): FakeSidecar =
  result.logPath = getTempDir() / "kaz-fake-" & $getCurrentProcessId() &
    "-" & $epochTime() & ".log"
  removeFile(result.logPath)
  writeFile(result.logPath, "")
  result.process = startProcess(
    "python3",
    args = ["tests/fixtures/fake_bedrock.py", result.logPath,
            $hangSeconds],
    options = {poUsePath, poStdErrToStdOut})
  let line = result.process.outputStream.readLine()
  result.port = parseInt(line.strip())

proc windows(fake: FakeSidecar): seq[tuple[a, b: float]] =
  for line in readFile(fake.logPath).splitLines():
    let parts = line.splitWhitespace()
    if parts.len == 2:
      result.add((parseFloat(parts[0]), parseFloat(parts[1])))

proc stop(fake: var FakeSidecar) =
  fake.process.terminate()
  discard fake.process.waitForExit()
  fake.process.close()
  removeFile(fake.logPath)

proc llmWorld(): SimServer =
  result = newHordeSim(maxTicks = 2304, maxGames = 1)
  result.gameEventLoggingEnabled = false

proc seatEveryoneLlm(engine: var DecisionEngine) =
  for seat in 0 ..< engine.seats.len:
    engine.seats[seat].isLlm = true
    engine.seats[seat].registered = true
    engine.seats[seat].prompt = "hold the line"
    engine.seats[seat].label = "prompt"

block allFourSeatsGoOutInOneParallelBatch:
  ## Every reply takes 150 ms of server time, so four SEQUENTIAL calls would
  ## produce four disjoint windows and four PARALLEL ones a single overlapping
  ## block. Without the delay the fake answers in microseconds and the windows
  ## never overlap however they were issued, which would make the assertion
  ## vacuous.
  var fake = startFake(hangSeconds = 0.15)
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
    "http://127.0.0.1:" & $fake.port)
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "test-token")
  putEnv("AWS_REGION", "us-west-2")
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  check(not engine.client.disabled,
    "the client must pick up the sidecar credentials")
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  let records = engine.turn(world, 0, 24, 0)
  let seen = fake.windows()
  check(seen.len == 4,
    "one call per seat per turn; the fake saw " & $seen.len)
  ## CONCURRENCY, measured: the batch's whole wall span must be far shorter
  ## than the sum of the four call durations. A sequential loop spends the sum;
  ## a parallel batch spends roughly one call. (libcurl holds the second
  ## connection to a new host back until the first is established, so the
  ## first window is its own — three of four overlapping exactly, at half the
  ## sequential cost, is what genuine parallelism looks like here.)
  var
    spanLo = 1e9
    spanHi = 0.0
    total = 0.0
  for w in seen:
    spanLo = min(spanLo, w.a)
    spanHi = max(spanHi, w.b)
    total += w.b - w.a
  let span = spanHi - spanLo
  check(span < total * 0.75,
    "the four requests took " & $span & " s of wall clock against " & $total &
      " s of summed call time — the batch is SEQUENTIAL, and at four seats " &
      "that quadruples the episode for nothing")
  ## And at least three of the four are in flight at the same instant.
  var maxConcurrent = 0
  for probe in seen:
    var live = 0
    for w in seen:
      if w.a <= probe.a and probe.a <= w.b:
        inc live
    maxConcurrent = max(maxConcurrent, live)
  check(maxConcurrent >= 3,
    "only " & $maxConcurrent & " of four requests were ever in flight together")

  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat], "seat " & $seat & " has no directive")
    check(engine.directives[seat].source == dsLlm,
      "seat " & $seat & " did not take the LLM's answer")
    check(engine.directives[seat].orders.len == 1, "one order per seat")
    check(engine.directives[seat].orders[0].intent == intScreen,
      "the fake's intent must survive the parse")
    ## The reply named no id, so the parser assigned it to this seat's own
    ## hero by position — and it must be THIS seat's hero.
    check(engine.directives[seat].orders[0].cogIndex == seat,
      "a seat's order must drive its own hero")
  var fallbacks = 0
  for record in records:
    if parseJson(record){"k"}.getStr() == "fallback":
      inc fallbacks
  check(fallbacks == 0, "a healthy batch writes no fallback records")
  fake.stop()
  delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
  delEnv("AWS_BEARER_TOKEN_BEDROCK")

block aHungProviderIsBoundedByThePerTurnBudget:
  ## The sidecar sleeps far past both deadlines. The turn must still return,
  ## inside turnBudgetMs plus one whole-second rounding, with every seat on the
  ## scripted fallback and a `fallback` record naming the cause.
  var fake = startFake(hangSeconds = 30.0)
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
    "http://127.0.0.1:" & $fake.port)
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "test-token")
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  let began = epochTime()
  let records = engine.turn(world, 0, 24, 0)
  let elapsed = epochTime() - began
  check(elapsed < float(world.config.turnBudgetMs) / 1000.0 + 3.0,
    "a hung provider must be bounded: the turn took " & $elapsed & " s " &
      "against a " & $world.config.turnBudgetMs & " ms budget")
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat],
      "NO FAILURE MODE LEAVES A HERO UNACTUATED: seat " & $seat &
        " has no directive")
    check(engine.directives[seat].source == dsFallback,
      "a timed-out seat plays the fallback")
    check(engine.directives[seat].orders.len == 1,
      "the fallback still issues one order")
  var causes: seq[string]
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      causes.add(node{"cause"}.getStr())
  check(causes.len >= 4, "every timed-out seat writes a fallback record")
  for cause in causes:
    check(cause in ["timeout", "transport_error", "parse_error", "throttled",
                    "no_credentials", "budget_guard"],
      "fallback.cause " & cause & " is outside the declared enum")
  fake.stop()
  delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
  delEnv("AWS_BEARER_TOKEN_BEDROCK")

block noCredentialsFallsBackInstantlyAndRecordsIt:
  delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
  delEnv("AWS_BEARER_TOKEN_BEDROCK")
  delEnv("ANTHROPIC_API_KEY")
  delEnv("ANTHROPIC_API_KEY_URI")
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  check(engine.client.disabled,
    "with no credentials the client must disable itself, so an offline " &
      "certification completes in seconds instead of waiting on a network")
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  let began = epochTime()
  let records = engine.turn(world, 0, 24, 0)
  check(epochTime() - began < 1.0,
    "a credential-less turn must cost no network wait at all")
  var noCreds = 0
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback" and
        node{"cause"}.getStr() == "no_credentials":
      inc noCreds
  check(noCreds == 4,
    "an LLM seat that CANNOT call is a fallback, not a scripted policy: " &
      "without the record llmTurns and fallbackTurns both read 0 for an " &
      "episode in which nothing but fallbacks happened")

block theBudgetGuardSettlesEarlyRatherThanOverrunning:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  ## Two more full turns would not fit inside the engine's own wall-clock stop.
  let elapsed = world.config.wallClockBudgetSeconds -
    (world.config.turnBudgetMs div 1000)
  let records = engine.turn(world, 20, 24, elapsed)
  check(engine.llmOff, "the budget guard must latch")
  var guarded = false
  for record in records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      guarded = true
  check(guarded, "the guard must name the turn it fired on")
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat],
      "every seat still gets a directive after the guard fires")

block theShippedVariantsPaceThemselvesInsideTheBudget:
  ## Read from the MANIFEST, not from the test config: the shipped rate floor
  ## and clock are what the league runs, and the test fixture deliberately
  ## sets turnSpacingMs to 0 because it never calls an LLM.
  let manifest = parseJson(readFile("coworld_manifest_template.json"))
  for variant in manifest["variants"]:
    let
      cfg = variant["game_config"]
      id = variant["id"].getStr()
      seats = cfg["num_agents"].getInt()
      spacing = cfg["turnSpacingMs"].getInt()
      budget = cfg["turnBudgetMs"].getInt()
      stop = cfg["wallClockBudgetSeconds"].getInt()
    ## The Bedrock sidecar caps 30 requests/minute PER EPISODE. Four seats at
    ## the shipped 9 s spacing is 4 x 60 / 9 = 26.7 req/min.
    let perMinute = seats * 60_000 div max(1, spacing)
    check(perMinute <= 30,
      id & ": four seats at " & $spacing & " ms spacing is " & $perMinute &
        " req/min, over the sidecar's 30/min episode cap")
    ## The spacing exceeds the turn budget, so the SPACING — not the model —
    ## sets the episode's length.
    check(spacing > budget,
      id & ": turnSpacingMs must exceed turnBudgetMs or the model paces " &
        "the episode")
    check(cfg["attempt1Ms"].getInt() + cfg["retryMs"].getInt() <= budget,
      id & ": both deadlines must fit inside one turn budget")
    let
      turns = max(1, cfg["maxTicks"].getInt() div cfg["turnTicks"].getInt()) *
        max(1, cfg["maxGames"].getInt())
      worstSpacing = turns * spacing div 1000
      lobbyCap = cfg["lobbyJoinTimeoutTicks"].getInt() div TargetFps
      worst = worstSpacing + lobbyCap + 60 + 20
    check(worst <= stop,
      id & ": the absolute worst case is " & $worst & " s against a " &
        $stop & " s engine stop")
    ## 60 % of the assumed 1200 s episodeTimeoutSeconds.
    check(stop <= 720,
      id & ": the engine stop must sit inside 60% of the episode timeout")

block aSeatNeverGoesUnactuatedAfterTurnZero:
  var world = llmWorld()
  var engine = initDecisionEngine(world)
  ## A seat that never registered is `phalanx` by construction.
  engine.ctl.observeHeroes(world)
  discard engine.turn(world, 0, 24, 0)
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat],
      "an unregistered seat must still have a directive")
    check(engine.directives[seat].source == dsScripted,
      "an unregistered seat plays the published default")
  ## A seat that drops mid-episode keeps playing: the control layer always has
  ## a directive — this turn's, else last turn's, else phalanx's.
  var directive = engine.phalanxFor(world, world.commandedCogs(1))
  check(directive.orders.len == 1, "phalanxFor always answers")

echo "test_engine: ok"
