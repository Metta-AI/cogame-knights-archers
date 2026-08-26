## Every drawn string fits its frame — the SHOUT-BUBBLE half, asserted on the
## real geometry rather than by eye.
##
## A canvas accepts a draw at a negative coordinate without complaint, so a
## bubble anchored where there is no room is invisible to the load signal, to
## the soak and to a screenshot (cogchemists, 2026-08-24: four speech bubbles
## drawn upward from cogs standing at the top of the arena, four sentences
## rendered as four white slivers, everything green).
##
## A cog's `say` is LLM-authored and becomes a REAL in-game shout: the bubble
## is rasterised into SPRITE PIXELS inside the sim (`buildShoutBubble` ->
## `blitFontText`, emitted by `addShouts`/`addBoardShouts`), so the browser
## never calls `fillText` for it and `viewer_smoke.mjs`'s canvas_text
## instrument is structurally blind to it (`total: 0`, which is evidence of
## nothing). This file is the gate that CAN see it: it asks the draw pass's own
## geometry — `shoutBubbleRectFor`, the same proc the packet builder uses —
## where every worst-case bubble lands, and asserts the whole rect is inside
## the board. Ported from the starter's own gate, coworld-ctf's
## `tests/test_pb_shouts.nim`, whose `shoutBubbleMaxHeight` /
## `shoutBubbleRectFor` this fork inherited with no callers.
##
## The DOM half — the commander `note` drawn as a `#killfeed` row by the real
## chrome — is `replay-viewer/text_fixture.html`, driven by
## `viewer_smoke.mjs --strict-text-bounds` in its own ci.yml step.

import
  std/unicode,
  kaz/[sim, global],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

const FullCap = "WWWWWWWWWW"
  ## The worst string the server can ever hand the bubble builder: the shout
  ## cap in the widest printable glyph. `sanitizeShout` keeps all of them.

block theCapIsWhatThisFixtureThinksItIs:
  check(FullCap.runeLen == ShoutMaxChars,
    "the fixture string is " & $FullCap.runeLen & " runes, the cap is " &
      $ShoutMaxChars)
  check(MaxSayRunes == ShoutMaxChars,
    "the directive cap and the shout cap must be the same number")
  check(sanitizeShout(FullCap) == FullCap,
    "the shout filter must keep a full-cap ASCII say verbatim")
  ## And a longer say is cut to the cap, so no bubble can ever be wider than
  ## the one this file measures.
  check(sanitizeShout(FullCap & FullCap).runeLen == ShoutMaxChars,
    "an over-long say must be cut to the cap before it reaches the bubble")

block aFullCapBubbleOnEveryCogAtOnceLandsInsideTheBoard:
  ## Worst positions first: the top edge (the cogchemists case), then the four
  ## corners and the side walls. Every cog shouts the full cap at the same
  ## time, which is also the frame the browser fixture renders.
  var sim = newHordeSim(maxTicks = 600, maxGames = 1)
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
    band = sim.shoutBubbleMaxHeight()
  check(band > 0, "the reserved band must have a measured height")
  var worst = h
  for spot in [(0, 0), (w div 2, 0), (w - 1, 0), (0, h - 1), (w div 2, h - 1),
               (w - 1, h - 1), (0, h div 2), (w - 1, h div 2),
               (w div 2, h div 2)]:
    for cogIndex in 0 ..< sim.players.len:
      sim.placePlayer(cogIndex, spot[0], spot[1])
    for cogIndex in 0 ..< sim.players.len:
      let rect = sim.shoutBubbleRectFor(cogIndex, FullCap)
      ## The whole rect, not just its anchor, is inside the board — which is
      ## the frame every spectator client fits whole into the viewport.
      check(rect.x >= 0, "bubble x " & $rect.x & " is off the west edge")
      check(rect.y >= 0, "bubble y " & $rect.y & " is off the north edge")
      check(rect.x + rect.w <= w,
        "bubble right edge " & $(rect.x + rect.w) & " is past " & $w)
      check(rect.y + rect.h <= h,
        "bubble bottom edge " & $(rect.y + rect.h) & " is past " & $h)
      check(rect.h <= band,
        "bubble height " & $rect.h & " exceeds the reserved band " & $band)
      worst = min(worst, rect.y)
  echo "worst-case bubble top y = ", worst, " (reserved band ", band,
    " px, board ", w, "x", h, ")"

block aBubbleThatCannotFitAboveTheCogFlipsBelowItNotOffFrame:
  ## The clamp is not allowed to be a silent squash: a cog on the top row must
  ## get a bubble whose whole height is on screen, below its tail.
  var sim = newHordeSim(maxTicks = 600, maxGames = 1)
  sim.placePlayer(0, sim.gameMap.width div 2, 0)
  let
    anchor = sim.players[0].shoutAnchor()
    rect = sim.shoutBubbleRectFor(0, FullCap)
  check(anchor.tailTipY - rect.h < 0,
    "the fixture cog must genuinely have no room above it")
  check(rect.y >= 0, "the flipped bubble must still start on the board")
  check(rect.y + rect.h <= sim.gameMap.height,
    "the flipped bubble must still end on the board")
  check(rect.y > anchor.tailTipY - rect.h,
    "the bubble must MOVE rather than clip")

block thePlacementIsAPureClampSoItNeverMovesABubbleThatFits:
  ## A bubble with room above the cog is placed exactly where the design puts
  ## it: centred on the shouter, its base at the tail tip.
  var sim = newHordeSim(maxTicks = 600, maxGames = 1)
  sim.placePlayer(0, sim.gameMap.width div 2, sim.gameMap.height div 2)
  let
    anchor = sim.players[0].shoutAnchor()
    rect = sim.shoutBubbleRectFor(0, FullCap)
  check(rect.x == anchor.x - rect.w div 2,
    "a bubble with room must stay centred on its shouter")
  check(rect.y == anchor.tailTipY - rect.h,
    "a bubble with room must sit with its base at the tail tip")

block everySayTheScriptedBaselinesEmitFitsAtEveryBoardPosition:
  ## The strings CI's own replay actually carries (`baselines.nim`: every
  ## scripted order ships one of these). They are shorter than the cap, so
  ## they must fit wherever the cap fits — asserted rather than assumed,
  ## because a shorter string with a different placement rule is exactly how a
  ## regression would hide.
  var sim = newHordeSim(maxTicks = 600, maxGames = 1)
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
  for say in ["on it", "loose", "back", "choke", FullCap]:
    for spot in [(0, 0), (w - 1, 0), (w div 2, 0), (w div 2, h - 1)]:
      for cogIndex in 0 ..< sim.players.len:
        sim.placePlayer(cogIndex, spot[0], spot[1])
        let rect = sim.shoutBubbleRectFor(cogIndex, say)
        check(rect.x >= 0 and rect.y >= 0,
          "\"" & say & "\" is placed off the board at " & $spot)
        check(rect.x + rect.w <= w and rect.y + rect.h <= h,
          "\"" & say & "\" overruns the board at " & $spot)

block theReservedBandIsIndependentOfWhoIsSpeaking:
  ## The band is sized from the CAP the server enforces, measured in the font
  ## the bubble is drawn in — not from whatever happens to be said this tick —
  ## so the scene does not jump when a remark lands.
  var sim = newHordeSim(maxTicks = 600, maxGames = 1)
  let band = sim.shoutBubbleMaxHeight()
  for say in ["a", "on it", FullCap]:
    let rect = sim.shoutBubbleRectFor(0, say)
    check(rect.h <= band,
      "\"" & say & "\" produced a bubble taller than the reserved band")
  check(sim.shoutBubbleMaxHeight() == band,
    "the reserved band must be a pure function of the cap and the board")

echo "test_shouts: ok"
