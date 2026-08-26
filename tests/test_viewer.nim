## The STATIC half of the viewer smoke: no browser, no wasm.
##
## `tools/ci/viewer_smoke.mjs` opens the built bundle in headless chromium and
## proves it DRAWS. This file proves the page it draws is the starter's page
## with a game block appended, not a lookalike written from scratch — the
## chrome is pinned by sha, the removed elements are asserted absent, and the
## beat CSS is asserted to cover exactly the kinds the sim emits.

import
  std/[json, md5, os, strutils],
  kaz/[sim, global, broadcast],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

let
  page = readFile("client/replay_broadcast.html")
  chrome = readFile("client/chrome_common.js")
  core = readFile("client/broadcast_core.js")

const ChromeCommonDigest = "80ea4eb19cee21cb61fb1f009f1f45ab"
  ## coworld-ctf's client/chrome_common.js, BYTE FOR BYTE. Everything
  ## knights-archers adds lives in the appended game block; nothing in this
  ## file is edited or reformatted, and this pin is what enforces that.

block theSharedChromeIsByteIdentical:
  let digest = getMD5(chrome)
  check(digest == ChromeCommonDigest,
    "client/chrome_common.js must be byte-identical to coworld-ctf's copy.\n" &
    "  got      " & digest & "\n  expected " & ChromeCommonDigest & "\n" &
    "  If the starter's file legitimately changed, update the pin AND say so.")
  check(chrome.contains("function markBeat("), "markBeat is inherited")
  check(chrome.contains("function renderBeatMarkers("),
    "renderBeatMarkers is inherited")
  check(chrome.contains("function ingestBeats("), "ingestBeats is inherited")
  check(chrome.contains("function setVerdict("), "setVerdict is inherited")

block theBroadcastCoreDiffersInExactlyOneIdentifier:
  ## The design pins this: byte-for-byte apart from the single
  ## `window.CTF_WIRE` -> `window.KAZ_WIRE` identifier that
  ## tools/gen_wire_constants.nim emits.
  check(core.contains("window.KAZ_WIRE"), "broadcast_core must read KAZ_WIRE")
  check(not core.contains("CTF_WIRE"), "no CTF_WIRE identifier may survive")
  var renamed = core.replace("KAZ_WIRE", "CTF_WIRE")
  let digest = getMD5(renamed)
  const BroadcastCoreDigest = "d85ac7bc278a7cd244be219b7ca65eb9"
  check(digest == BroadcastCoreDigest,
    "client/broadcast_core.js differs from coworld-ctf's copy by MORE than " &
    "the KAZ_WIRE identifier.\n  got      " & digest &
    "\n  expected " & BroadcastCoreDigest)

block theInheritedChromeIsAllStillThere:
  for id in ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
             "chrome", "scorebug", "plates-l", "plates-r", "clock",
             "bannerlane", "killfeed", "fpv", "povBadge", "mmwarn",
             "transport", "scrub", "momentum", "lulls", "scrub-win",
             "scrub-head", "endcard"]:
    check(page.contains("id=\"" & id & "\""),
      "the inherited chrome element #" & id & " is missing")
  for control in ["btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end",
                  "btn-loop", "btn-skip", "btn-spoilers", "speedchips",
                  "tick-clock"]:
    check(page.contains("id=\"" & control & "\""),
      "the transport control #" & control & " is missing")

block theRemovedElementsAreReallyGone:
  ## The design's removal list, checked as absence rather than as display:none.
  for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-in",
             "zoom-out", "zoom-slider", "zoom-read"]:
    check(not page.contains("id=\"" & id & "\""),
      "#" & id & " must be REMOVED (the board is a fixed arena that always fits)")
  check(not page.contains("attachMinimap"),
    "the attachMinimap call goes with the minimap")
  check(not page.contains("#endcard .ec-heart"),
    "the endcard heart glyphs go with the objective they belonged to")
  check(not page.contains("capturedHeartsHtml"),
    "the captured-heart column goes with the objective it belonged to")
  for kind in ["steal", "return", "capture", "hillflip", "hillhold"]:
    check(not page.contains(".beat-marker." & kind),
      ".beat-marker." & kind & " must be removed: that kind is never emitted")

block theTransportRulesHold:
  check(page.contains("--hudscale") and page.contains("--band") and
        page.contains("--topband"),
    "relayout() must set --hudscale, --band and --topband")
  check(page.contains("setProperty('--hudscale'") or
        page.contains("--hudscale',"),
    "--hudscale must be set on the document element by relayout()")
  check(page.contains("#endcard {") and
        page.contains("bottom: var(--band, 0px)"),
    "the endcard must stop at var(--band) so the scrubber stays clickable")
  check(page.contains("$('endcard').classList.remove('on');"),
    "every seek must dismiss the endcard")
  ## No overlay may sit inside the transport band: every knights-archers
  ## addition is positioned in the board region or the TOP band. The pressure
  ## strip is INSIDE the top band as the scorebug's own last grid row, so
  ## relayout()'s --topband measurement reserves room for it -- offsetting it
  ## up by 15 units drew it over the second row of plates and the TIME LEFT
  ## caption (r1 review N15).
  check(page.contains("#kaz-pressure {\n  grid-column: 1 / -1;"),
    "the pressure strip must be a scorebug grid row, not an absolute overlay")
  check(page.contains("(scorebug || chrome).appendChild(wrap);"),
    "the pressure strip must be appended to #scorebug, so --topband holds it")
  check(not page.contains("top: calc(var(--topband, 0px) - 15 * var(--u));"),
    "the pressure strip must never be offset UP into the plates")
  check(not page.contains("#kaz-pressure {\n  position: absolute;"),
    "the pressure strip must not be an absolutely-positioned overlay")

block theScrubberBeatsAreLabelledClickableButtons:
  check(page.contains("function kazBeat(s, tick, kind, side, label)"),
    "the game block's beat builder must be kazBeat")
  check(not page.contains("function markBeat("),
    "the game block must NEVER declare markBeat: a hoisted function " &
    "declaration would shadow the chrome alias block's own `var markBeat = " &
    "C.markBeat` (cogame-tandem, 2026-08-23)")
  check(page.contains("document.createElement('button')") and
        page.contains("el.setAttribute('aria-label', label)"),
    "every beat must be a labelled BUTTON")
  check(page.contains("CTX.send('s:' + tick)"), "a beat must seek on click")
  ## CSS for EVERY kind the sim emits, and no kind it does not.
  const emitted = ["wavestart", "closecall", "casualty", "breach", "waveover"]
  for kind in emitted:
    check(page.contains(".beat-marker." & kind & " {"),
      "no CSS for the beat kind " & kind)
  ## And the game block draws no other kind.
  for kind in ["tagout", "gamestart", "gameover"]:
    check(not page.contains(".beat-marker." & kind & " {"),
      ".beat-marker." & kind & " is styled but never emitted")

block everyEntryPointIsHandedTheContext:
  ## The appended block's IIFE runs AFTER the main one, so the main IIFE's
  ## `install(KAZ_CTX)` call is a no-op and the block's CTX is null until
  ## something hands it over. `ensureScorebug` and `renderScorebug` both fire
  ## BEFORE the frame hook on the very first frame, so an entry point called
  ## without the context takes the whole shell down with
  ## "Cannot read properties of null" — which is exactly what the browser load
  ## test reported.
  for call in ["KnightsArchersChrome.frame(s, KAZ_CTX, jumped)",
               "KnightsArchersChrome.buildPlates(sides, KAZ_CTX)",
               "KnightsArchersChrome.plates(s, KAZ_CTX)",
               "KnightsArchersChrome.endcard(s, head, how, KAZ_CTX)"]:
    check(page.contains(call), "the entry point " & call & " must be " &
      "called WITH the context, or the block runs on a null CTX")
  check(page.contains("KnightsArchersChrome.event(e, s, KAZ_CTX)"),
    "the event hook must be handed the context too")
  ## And every use of the context inside the block goes through a guarded
  ## wrapper, so a missing context costs a plainer readout, never a dead
  ## viewer.
  let banner2 = page.find("KNIGHTS-ARCHERS additions to the inherited")
  let body = page[banner2 .. ^1]
  for direct in ["CTX.esc(", "CTX.shortName(", "CTX.fmt(", "CTX.pushFeed(",
                 "CTX.banner(", "CTX.send("]:
    var uses = 0
    var at = body.find(direct)
    while at >= 0:
      inc uses
      at = body.find(direct, at + 1)
    check(uses <= 1,
      direct & " is used " & $uses & " times: it must be reached only " &
        "through this block's own guarded wrapper")

block theFeedIsHandedANodeNotAString:
  ## The inherited `pushFeed` takes a NODE. Handing it an HTML string threw
  ## "Failed to execute 'insertBefore' on 'Node'" on the first feed row, which
  ## latched static_replay.js into `failed` and FROZE the replay one tick in —
  ## with the load signal green and the scrub readouts green, because seeking
  ## skips the killing frame. Only --soak saw it.
  let at = page.find("KNIGHTS-ARCHERS additions to the inherited")
  let body2 = page[at .. ^1]
  check(body2.contains("row.className = 'feed-row'"),
    "kazFeed must build a .feed-row element")
  check(body2.contains("CTX.pushFeed(row)"),
    "kazFeed must hand pushFeed a NODE, never an HTML string")
  check(not body2.contains("CTX.pushFeed(html"),
    "pushFeed must never be handed a string")

block theGameBlockCannotShadowTheChromeAliases:
  ## The tandem 2026-08-23 trap, generalised: the appended block must not
  ## declare ANY top-level name the chrome alias block aliases.
  let banner = page.find("KNIGHTS-ARCHERS additions to the inherited")
  check(banner > 0, "the appended block must carry the banner comment")
  let appended = page[banner .. ^1]
  const aliases = [
    "markBeat", "renderBeatMarkers", "ingestBeats", "setVerdict",
    "ingestLeadSeries", "ingestLullSpans", "renderMomentum", "pushFeed",
    "banner", "setSpoilers", "getSpoilers", "teamPolicies", "teamName",
    "shortName", "rosterName", "stripSeatSuffix", "setName"]
  for alias in aliases:
    check(not appended.contains("function " & alias & "("),
      "the game block declares `function " & alias & "`, which HOISTS over " &
      "the chrome alias of the same name")
    check(not appended.contains("\n  var " & alias & " ="),
      "the game block declares `var " & alias & "`, which shadows the alias")

block theScorebugSurvivesAThreeSixtyPixelIframe:
  check(page.contains(".plate-name {") and
        page.contains("flex: 1 1 auto;") and
        page.contains("min-width: 3.2em;"),
    ".plate-name needs flex: 1 1 auto and min-width: 3.2em so a policy name " &
    "never collapses to a bare ellipsis in the ~360px featured-match iframe")
  check(page.contains("#stage.tiny .kaz-shots,"),
    "under .tiny the shots/swings numeral must be hidden")
  check(page.contains("#stage.tiny #kaz-segs { display: none; }"),
    "under .tiny the pressure bar must drop its per-zombie segments")
  check(page.contains("boardW <= 620") or page.contains("tiny"),
    "the inherited .tiny density system must survive")

block theHordeReadoutsArePresent:
  for id in ["kaz-pressure", "kaz-bar", "kaz-fill", "kaz-segs", "kaz-read",
             "kaz-chalk", "kaz-wave", "ec-waves", "ec-rows-squad"]:
    check(page.contains("kaz-pressure") or page.contains(id),
      "the readout #" & id & " is missing")
    check(page.contains(id), "the readout #" & id & " is missing")
  check(page.contains("DEAD WALKING"), "the pressure bar's numeral readout")
  check(page.contains("CLOSEST CALL"), "the closest-call chalk line label")
  ## The chalk line and its caption are drawn on the BOARD, beside each other.
  ## #kaz-chalk is a child of #stage, which spans both bands, so a `top: 0`
  ## element puts its label inside the opaque scorebug band where #chrome
  ## (z-index 10 against the chalk's 6) draws over it -- the caption appeared
  ## nowhere in the reviewed run's screenshot (r1 review N16).
  check(page.contains("top: var(--topband, 0px);\n  bottom: var(--band, 0px);"),
    "the chalk line must span the BOARD region, not the whole stage")
  check(page.contains("IS CHARGING"), "the lunge feed row")
  check(page.contains("IS THROUGH THE GATE"), "the breach banner")
  check(page.contains("THE LINE HOLDS"), "the wave-cleared banner")

block theCommanderLinesWrapInsideTheFeedColumn:
  ## A `note` is a SENTENCE of up to 160 runes, and the inherited .feed-row is
  ## sized to its content because every string the starter put in it was a
  ## pre-bounded 10-char name. At full cap the row grew out of both sides of
  ## the frame at every canvas size (found by replay-viewer/text_fixture.html).
  ## Item 15: widen the band, never shorten the text.
  check(page.contains("#killfeed .feed-row.say,"),
    "the game's own feed rows must have their own wrapping rule")
  check(page.contains("overflow-wrap: anywhere;") and
        page.contains("white-space: normal;"),
    "a full-cap note must wrap inside the feed column")
  check(not page.contains("text-overflow: ellipsis;\n  white-space: nowrap"),
    "a sentence must never be ellipsised: widen the band instead")

block theMomentumGraphAndTheVerdictAreRetargeted:
  ## The inherited momentum graph plots a per-team LIVES LEAD, and the
  ## inherited verdict chip says "<TEAM> WINS". Neither means anything for one
  ## cooperative squad: sim.winner is always Red here, so the chip read
  ## "RED WINS" even on a breach that lost the wave, and the caption still read
  ## LIVES LEAD over two horde series (r1 review N18).
  check(page.contains("label.textContent = 'KILLS vs HORDE PRESSURE';"),
    "the game block must retarget the momentum caption")
  check(page.contains("if (s.over && !KAZ_MODE) setVerdict(s.over);"),
    "KAZ_MODE must not raise the inherited team verdict chip")
  ## And the two series really are the horde's, on one scale.
  var world = newHordeSim(maxTicks = 600, maxGames = 2)
  world.gameEventLoggingEnabled = false
  world.zombiesKilled = 90
  let state = parseJson(world.buildStateJson(
    newJArray(), true, 1, 600, false, true, -1, -1,
    leadSeries = @[@[0, 0, 0], @[120, 50, 40]]))
  check(state.hasKey("lead"), "the lead series must ship")
  check(state["lead"]["teams"].len == 2, "two horde series")
  check(state["lead"]["teams"][0].getStr() == "kills" and
        state["lead"]["teams"][1].getStr() == "pressure",
    "the series must be named for what they are, not for teams")

block theWorstCaseTextFixtureIsShippedAndDriven:
  ## Item 15's last bullet: a repo whose viewer draws LLM-authored text ships a
  ## worst-case renderer fixture driven by `viewer_smoke.mjs
  ## --strict-text-bounds` in its own ci.yml step. Both halves are asserted
  ## here so neither can be quietly dropped: the page, and the step that runs
  ## it. (The in-sim shout bubble's geometry is tests/test_shouts.nim; the
  ## browser cannot see it, because it is blitted into sprite pixels.)
  const fixturePath = "replay-viewer/text_fixture.html"
  check(fileExists(fixturePath), fixturePath & " is missing")
  let fixture = readFile(fixturePath)
  check(fixture.contains("replay_broadcast.html"),
    "the fixture must load the REAL chrome page, not a copy of it")
  check(fixture.contains("window.KnightsArchersChrome"),
    "the fixture must drive the real appended game block")
  check(fixture.contains("data-replay-loaded") and
        fixture.contains("data-replay-error"),
    "the fixture must report through the markers viewer_smoke.mjs reads")
  check(fixture.contains("fillText"),
    "the fixture must mirror every measured line into a canvas, or " &
      "--strict-text-bounds gates a structurally vacuous 0")
  let ci = readFile(".github/workflows/ci.yml")
  check(ci.contains("text_fixture.html"),
    "ci.yml must drive replay-viewer/text_fixture.html in its own step")
  let at = ci.find("text_fixture.html")
  check(ci.find("--strict-text-bounds", at) > at,
    "the fixture step must pass --strict-text-bounds")

block noStarterIdentifierSurvives:
  for path in walkDirRec("src"):
    if not path.endsWith(".nim"):
      continue
    let text = readFile(path)
    for line in text.splitLines():
      let bad = line.contains("CTF_") or line.contains("ctf_") or
        line.contains("CtfMap") or line.contains("CtfError")
      check(not bad, path & ": a ctf_/CTF_ identifier survives: " & line)
  for path in ["client/replay_broadcast.html", "client/broadcast_core.js",
               "replay-viewer/static_replay.js",
               "replay-viewer/static_replay_worker.js",
               "replay-viewer/kaz_replay.nim", "replay-viewer/config.nims"]:
    let text = readFile(path)
    check(not text.contains("CTF_") and not text.contains("ctf_"),
      path & " still carries a ctf_/CTF_ identifier")

block theFrameBuildersSurviveAFullBoard:
  ## The docker smoke crashed on the FIRST tick that had a zombie on it: the
  ## horde's sprite pool sat above the u16 wire ceiling, which no test touched
  ## because none of them had ever rendered a frame with a zombie in it. This
  ## block renders both frame builders against a saturated board — forty
  ## marching zombies and sixteen arrows in flight — so every sprite id the
  ## horde can ever emit is packed onto the wire here rather than in CI.
  var world = newHordeSim(maxTicks = 2304, maxGames = 1)
  world.gameEventLoggingEnabled = false
  for i in 0 ..< MaxZombies:
    if world.aliveZombies >= world.config.spawnCapAlive:
      break
    world.spawnOneZombie()
  ## Spread them over the whole board and give them every heading, so every
  ## rotation and both shamble frames get baked.
  for i in 0 ..< world.zombies.len:
    let spot = world.nearestWalkable(
      100 + (i * 37) mod (MapWidth - 200),
      60 + (i * 53) mod (MapHeight - 120))
    world.zombies[i].ux = spot.x * MotionScale
    world.zombies[i].uy = spot.y * MotionScale
    world.zombies[i].lungeTarget = (if i mod 3 == 0: i mod 4 else: -1)
  check(world.zombies.len >= 20,
    "the fixture needs a real horde, got " & $world.zombies.len)
  for i in 0 ..< 16:
    world.players[2].fireCooldown = 0
    world.players[2].aimBrads = (i * 16) mod AimBradsTurn
    world.startHeroAttacks([2])
  check(world.arrows.len == 16, "sixteen arrows in flight")
  world.aliveZombies = world.recountAliveZombies()

  ## Both shamble frames.
  for tick in [0, 8]:
    world.tickCount = tick
    var viewer = initGlobalViewerState()
    var nextViewer: GlobalViewerState
    let frame = world.buildSpriteProtocolUpdates(viewer, nextViewer)
    check(frame.len > 0, "the board frame must carry the horde")
    viewer = nextViewer
  for seat in 0 ..< world.seatCount():
    var nextState = initPlayerViewerState()
    let frame = world.buildSpriteProtocolPlayerUpdates(
      seat, initPlayerViewerState(), nextState)
    check(frame.len > 0, "seat " & $seat & "'s frame must carry the horde")

  ## And the chrome frame the appended block reads: every readout it draws has
  ## to be in the state JSON, or the pressure bar and the plates are blank.
  let state = parseJson(world.buildStateJson(
    newJArray(), true, 1, 2304, false, true, -1, -1))
  for key in ["wave", "waves", "turn", "turns", "heroes", "horde"]:
    check(state.hasKey(key), "the chrome frame is missing " & key)
  check(state["heroes"].len == 4, "four hero plates")
  for key in ["alive", "leaderGatePx", "pressurePct", "spawnGatePx",
              "closestCallPx", "gateX", "breachX", "teamScore"]:
    check(state["horde"].hasKey(key), "the horde block is missing " & key)

echo "test_viewer: ok"
