## The STATIC half of the viewer smoke: no browser, no wasm.
##
## `tools/ci/viewer_smoke.mjs` opens the built bundle in headless chromium and
## proves it DRAWS. This file proves the page it draws is the starter's page
## with a game block appended, not a lookalike written from scratch — the
## chrome is pinned by sha, the removed elements are asserted absent, and the
## beat CSS is asserted to cover exactly the kinds the sim emits.

import
  std/[md5, os, strutils],
  kaz/sim

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
  ## addition is positioned in the board region or the TOP band.
  check(page.contains("top: calc(var(--topband, 0px) - 15 * var(--u));"),
    "the pressure bar must sit in the TOP band, never in the transport band")

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
  check(page.contains("IS CHARGING"), "the lunge feed row")
  check(page.contains("IS THROUGH THE GATE"), "the breach banner")
  check(page.contains("THE LINE HOLDS"), "the wave-cleared banner")

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

echo "test_viewer: ok"
