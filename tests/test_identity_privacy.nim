## The TWO NAME SPACES, asserted from both sides.
##
## Agents see anonymous cog aliases and nothing else — no sprite label in a
## seat frame, no shout bubble, no LLM system-or-user message and no
## `directive` record may ever carry a real policy address. The BROADCAST
## stream, `roster[].name`, the DOM scorebug and `results.names` MUST carry
## it: hiding it there would make the featured match anonymous.

import
  std/[json, strutils],
  kaz/[sim, broadcast, global, decide, control, directives, baselines, llm],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

const Sentinel = "ply-sentinel-policy-9f3a"

var world = newHordeSim(maxTicks = 2304, maxGames = 1)
world.gameEventLoggingEnabled = false
for seat in 0 ..< world.seatCount():
  world.seatNames[seat] = Sentinel & "-" & $seat
  world.players[seat].address = Sentinel & "-" & $seat

var engine = initDecisionEngine(world)
for i in 0 ..< 30:
  world.spawnZombies()
  world.updateZombies()
world.aliveZombies = world.recountAliveZombies()
engine.ctl.observeHeroes(world)
for seat in 0 ..< world.seatCount():
  engine.directives[seat] = scriptedDirective(
    engine.ctl, world, blPhalanx, world.commandedCogs(seat))
  engine.haveDirective[seat] = true

block noSentinelReachesASeat:
  for seat in 0 ..< world.seatCount():
    let view = engine.seatViewJson(world, seat, 3, 24)
    check(not view.contains(Sentinel),
      "the seat view leaked a policy address to seat " & $seat)
    let user = userMessage(
      "hold a line, do not chase", view)
    check(not user.contains(Sentinel), "the LLM user message leaked it")
    check(not systemPromptFor(world.roleForSeat(seat)).contains(Sentinel),
      "the LLM system prompt leaked it")

block noSentinelInADirectiveRecord:
  for seat in 0 ..< world.seatCount():
    let record = engine.directives[seat].boundedDirectiveRecord(
      1, 3, seat, world.cogAlias(seat), world.roleForSeat(seat))
    check(not record.contains(Sentinel),
      "a directive record leaked a policy address")
    let node = parseJson(record)
    check(node["alias"].getStr() == world.cogAlias(seat),
      "the record carries the ALIAS")

block noSentinelInARegisterRecord:
  ## The register record carries the policy LABEL — which an operator chooses
  ## and which is spectator-side — but never the prompt.
  let record = registerRecord(
    0, world.cogAlias(0), world.roleForSeat(0), "warden", "llm", "phalanx")
  check(not record.contains("hold a line"), "the prompt must never be written")
  let node = parseJson(record)
  check(node["k"].getStr() == "register", "it is a register record")
  check(node["policy"].getStr() == "warden", "the label is carried")

block noSentinelInASeatFrame:
  ## A seat's own Sprite v1 frame: sprite LABELS are read off the wire by
  ## every bot, so a label carrying an address hands rivals a free roster.
  var nextState = initPlayerViewerState()
  let frame = world.buildSpriteProtocolPlayerUpdates(
    0, initPlayerViewerState(), nextState)
  var text = ""
  for b in frame:
    text.add(char(b))
  check(not text.contains(Sentinel),
    "a seat frame leaked a policy address in a sprite label")

block noSentinelInAShoutBubble:
  discard world.applyShout(0, "north")
  var nextState = initPlayerViewerState()
  let frame = world.buildSpriteProtocolPlayerUpdates(
    1, initPlayerViewerState(), nextState)
  var text = ""
  for b in frame:
    text.add(char(b))
  check(not text.contains(Sentinel), "a shout bubble leaked a policy address")

block theBroadcastSideMUSTCarryIt:
  let state = world.buildStateJson(
    newJArray(), true, 1, 2304, false, true, -1, -1)
  check(state.contains(Sentinel),
    "the BROADCAST frame must carry the real policy name — the featured " &
      "match is anonymous without it")
  let node = parseJson(state)
  var sawRosterName = false
  for entry in node["roster"]:
    if entry["name"].getStr().contains(Sentinel):
      sawRosterName = true
    check(entry["alias"].getStr().startsWith("KNIGHT-") or
          entry["alias"].getStr().startsWith("ARCHER-"),
      "the roster's alias column is the ANONYMOUS one")
  check(sawRosterName, "roster[].name must be the real policy name")
  var sawHeroName = false
  for hero in node["heroes"]:
    if hero["name"].getStr().contains(Sentinel):
      sawHeroName = true
  check(sawHeroName, "the scorebug plates must carry the real policy names")

block theResultsDocumentMUSTCarryIt:
  let results = parseJson(world.heroResultsJson())
  var sawName = false
  for name in results["names"]:
    if name.getStr().contains(Sentinel):
      sawName = true
  check(sawName, "results.names must be the real policy names")
  for alias in results["alias"]:
    check(alias.getStr().startsWith("KNIGHT-") or
          alias.getStr().startsWith("ARCHER-"),
      "results.alias is the in-game name")

echo "test_identity_privacy: ok"
