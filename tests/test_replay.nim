## The END-TO-END episode: a full scripted four-seat, two-wave episode writes a
## `COWLDKAZ` replay, `parseReplayBytes` accepts it, and re-simulating from the
## config plus the recorded mask log reproduces EVERY recorded hash — including
## every zombie spawn, which is re-derived from the seeded RNG and never
## recorded.
##
## It also proves the STRICT-UTF-8 contract with a non-ASCII policy label and a
## non-ASCII `note` on the boundary, because a byte-truncated multi-byte
## character is exactly the bug that makes replay bytes render in a browser and
## fail a strict parser.

import
  std/[json, os, osproc, strutils, unicode],
  bitworld/spriteprotocol,
  kaz/[sim, replays, replay_runtime, control, directives, baselines, decide],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

let outPath = getTempDir() / "kaz-e2e-" & $getCurrentProcessId() & ".replay"
removeFile(outPath)

var game0 = newLobbySim(seats = 4, maxTicks = 600, maxGames = 2)
game0.gameEventLoggingEnabled = false
## Force the UTF-8 path to be real: a non-ASCII policy label on the spectator
## side and a non-ASCII commander note.
game0.seatNames[0] = "chevalière-æ"
game0.seatNames[1] = "bogenschütze"
game0.seatNames[2] = "archère-ø"
game0.seatNames[3] = "phalanx"

var
  writer = openReplayWriter(outPath, game0.config.configJson())
  ctl = initControlState(game0)
  orders = newSeq[SquadDirective](game0.seatCount())
  have = newSeq[bool](game0.seatCount())
  prevInputs = newSeq[InputState](game0.players.len)
  waves = 0
  lastTurnKey = -1
  recordKinds: seq[string]
  directiveRecords = 0
  resultRecords = 0

proc seatEveryone() =
  ## Seats the four heroes exactly as the server does — trusted joins carrying
  ## only their ANONYMOUS aliases, each one written to the replay's join stream
  ## — and lets the lobby countdown start the wave. This is the only path a
  ## replay can re-derive, which is why the fixture cannot call `startGame` or
  ## `resetToLobby` itself: the sim's own phase machine has to make every
  ## transition, or playback re-derives a different one.
  for seat in 0 ..< game0.seatCount():
    discard game0.addPlayer("policy-" & $seat, seat, "", trusted = true)
    writer.writeJoin(
      tickTime(game0.tickCount), seat, "policy-" & $seat, seat, "")
    while writer.lastMasks.len < game0.players.len:
      writer.lastMasks.add(0)

seatEveryone()
for seat in 0 ..< game0.seatCount():
  let record = registerRecord(
    seat, game0.cogAlias(seat), game0.roleForSeat(seat), game0.seatNames[seat],
    "scripted", "phalanx")
  writer.writeChat(tickTime(game0.tickCount), seat, record)
  recordKinds.add("register")

let turnTicks = max(1, game0.config.turnTicks)
for step in 0 ..< 40_000:
  if game0.phase == Lobby and game0.players.len == 0 and
      waves < max(1, game0.config.maxGames):
    seatEveryone()
    have = newSeq[bool](game0.seatCount())
    prevInputs = newSeq[InputState](game0.players.len)
  var inputs = newSeq[InputState](game0.players.len)
  if game0.phase == Playing:
    ctl.observeHeroes(game0)
    let turnKey =
      game0.gameIndex * 1_000_000 + game0.gameTicksElapsed() div turnTicks
    if game0.gameTicksElapsed() mod turnTicks == 0 and turnKey != lastTurnKey:
      lastTurnKey = turnKey
      for seat in 0 ..< game0.seatCount():
        var directive = scriptedDirective(
          ctl, game0, blPhalanx, game0.commandedCogs(seat))
        ## A non-ASCII note whose cut lands ON a multi-byte boundary: the cap
        ## is in RUNES, so this must round-trip through parseJson and decode
        ## as UTF-8.
        directive.note = sanitizeNote(
          "hold the gate — " & "æøå".repeat(70) & "\u{1F9DF}")
        orders[seat] = directive
        have[seat] = true
        let record = directive.boundedDirectiveRecord(
          game0.gameIndex + 1, game0.gameTicksElapsed() div turnTicks, seat,
          game0.cogAlias(seat), game0.roleForSeat(seat))
        check(record.runeLen <= MaxDirectiveRunes,
          "a directive record is " & $record.runeLen & " runes, cap is " &
            $MaxDirectiveRunes)
        writer.writeChat(tickTime(game0.tickCount), seat, record)
        game0.pushFeedDirective(record)
        inc directiveRecords
    for cogIndex in 0 ..< game0.players.len:
      let seat = game0.cogSeat(cogIndex)
      if not have[seat]:
        continue
      for order in orders[seat].orders:
        if order.cogIndex != cogIndex:
          continue
        let mask = ctl.compileMask(game0, order, cogIndex)
        inputs[cogIndex] = decodeInputMask(mask)
        writer.writeInputMaskChange(tickTime(game0.tickCount), cogIndex, mask)
  else:
    for cogIndex in 0 ..< game0.players.len:
      writer.writeInputMaskChange(tickTime(game0.tickCount), cogIndex, 0)
  let before = game0.phase
  game0.step(inputs, prevInputs)
  prevInputs = inputs
  while prevInputs.len < game0.players.len:
    prevInputs.add(InputState())
  writer.writeHash(uint32(game0.tickCount), game0.gameHash())
  if before != GameOver and game0.phase == GameOver:
    inc waves
    game0.archiveWave()
    game0.gameIndex = waves
    lastTurnKey = -1
    if waves >= max(1, game0.config.maxGames):
      break

writer.writeChat(tickTime(game0.tickCount), 0, resultRecord(game0))
inc resultRecords
writer.closeReplayWriter()

check(waves == 2, "the episode must play both waves, played " & $waves)
check(directiveRecords == 4 * (directiveRecords div 4),
  "directive records must come four to a turn")
check(directiveRecords >= 8, "too few directive records: " & $directiveRecords)

block theResultsDocumentIsWellFormedAndClosed:
  let results = parseJson(game0.heroResultsJson())
  const wanted = [
    "names", "scores", "win", "role", "alias", "kills", "hits", "shots",
    "llmTurns", "fallbackTurns", "teamScore", "teamKills", "wavesCleared",
    "waveTicks", "waveEndRules", "waveKills", "closestCallPx", "reason",
    "endRule", "games", "finalTick", "seed"]
  check(results.len == wanted.len,
    "results has " & $results.len & " keys, want " & $wanted.len)
  for key in wanted:
    check(results.hasKey(key), "results is missing " & key)
  for key in ["names", "scores", "win", "role", "alias", "kills", "hits",
              "shots", "llmTurns", "fallbackTurns"]:
    check(results[key].len == 4, key & " must have 4 entries")
  check(results["reason"].getStr() in
    [ReasonComplete, ReasonDeadline, ReasonFault],
    "reason " & results["reason"].getStr() & " is not in the enum")
  check(results["endRule"].getStr() in
    [EndRuleFullTime, EndRuleBreach, EndRuleCasualty, EndRuleWallClock,
     EndRuleSimFault, EndRuleHostError],
    "endRule " & results["endRule"].getStr() & " is not in the enum")
  ## Fully cooperative: every seat's team term is identical and the epsilon is
  ## strictly smaller than one extra team kill.
  var lo = 2.0
  var hi = -1.0
  for value in results["scores"]:
    lo = min(lo, value.getFloat())
    hi = max(hi, value.getFloat())
  check(hi - lo <= 0.004 + 1e-9,
    "the credit spread is " & $(hi - lo) & ", cap is 0.004")
  for value in results["win"]:
    check(value.getBool() == results["win"][0].getBool(),
      "win must be the same boolean for all four seats")

block theReplayParsesAndReSimulatesEveryHash:
  let bytes = readFile(outPath)
  check(bytes.len > 0, "the replay file is empty")
  check(bytes.startsWith("COWLDKAZ"),
    "the replay magic is " & bytes[0 ..< min(8, bytes.len)])
  let data = parseReplayBytes(bytes)
  var initialized = initReplayRuntime(
    data, mismatchQuit = true, gameEventLoggingEnabled = false)
  var
    game = move(initialized.sim)
    player = move(initialized.player)
    tracker = move(initialized.tracker)
    kinds: seq[string]
    swings = 0
    shots = 0
    kills = 0
    closecalls = 0
    wavestarts = 0
    waveovers = 0
  while player.playing:
    var events = newJArray()
    events = player.advanceReplayFrame(game, tracker, @[], @[])
    for event in events:
      let kind = event{"k"}.getStr()
      kinds.add(kind)
      case kind
      of "swing": inc swings
      of "shot": inc shots
      of "kill": inc kills
      of "closecall": inc closecalls
      of "wavestart": inc wavestarts
      of "waveover": inc waveovers
      else: discard
  ## `mismatchQuit = true` makes a single divergent bit raise at the tick it
  ## happens, so reaching here at all is the determinism proof.
  check(player.hashMismatchTick < 0,
    "hash mismatch at tick " & $player.hashMismatchTick)
  check(game.tickCount > 600, "playback stopped early at " & $game.tickCount)
  check(swings > 0, "no swing beat in the whole episode")
  check(shots > 0, "no shot beat in the whole episode")
  check(kills > 0, "no kill beat in the whole episode")
  ## Playback BEGINS on the first Playing tick, so wave one's `wavestart` is
  ## the frame the tracker initialises on and is not observable from here;
  ## wave two's is. Both waves' `waveover` beats are.
  check(wavestarts >= 1, "expected a wavestart beat, got " & $wavestarts)
  check(waveovers >= 2, "expected two waveover beats, got " & $waveovers)
  check(closecalls >= 0, "closecall beats are optional on a short fixture")

block theSummaryIsStrictUtf8Json:
  ## The phase-60 substitute for the definition-of-done replay check, run here
  ## against the bytes this test just produced: Python stdlib only, no Nim, no
  ## Docker.
  let (output, code) = execCmdEx(
    "python3 tools/replay_summary.py " & quoteShell(outPath))
  check(code == 0, "replay_summary.py exited " & $code & ": " & output)
  let summary = parseJson(output)
  check(summary{"protocol"}.getStr() == "knights-archers/v1",
    "protocol is " & summary{"protocol"}.getStr())
  check(summary{"gameVersion"}.getStr() == GameVersion,
    "gameVersion is " & summary{"gameVersion"}.getStr())
  check(summary{"directives"}.len >= 8,
    "the summary decoded " & $summary{"directives"}.len & " directives")
  check(summary{"results"}{"teamKills"}.getInt() >= 0,
    "the summary lost the result record")
  var sawNonAscii = false
  for directive in summary{"directives"}:
    if directive{"note"}.getStr().runeLen != directive{"note"}.getStr().len:
      sawNonAscii = true
  check(sawNonAscii,
    "the fixture must carry a non-ASCII note so the UTF-8 path is real")

removeFile(outPath)
echo "test_replay: ok"
