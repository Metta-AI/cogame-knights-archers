## Tolerant parsing and repair, and the RUNE discipline.
##
## Every cap in the reply schema is measured in RUNES and every truncation
## lands on a rune boundary. Slicing a string by BYTE index anywhere on the
## path to the replay is forbidden: a byte-truncated multi-byte character
## renders fine in a browser and then fails a strict UTF-8 parser.

import
  std/[json, strutils, unicode],
  kaz/[sim, directives]

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

const Ids = @["KNIGHT-alpha"]
const Cogs = @[0]

proc parseOne(text: string): SquadDirective =
  parseSquadDirective(extractJsonObject(text), Ids, Cogs, 40, 329, 1234, 658)

proc parseFails(text: string): bool =
  try:
    discard parseOne(text)
    false
  except CatchableError:
    true

block prosePrefixedAndFencedJson:
  let a = parseOne("""Sure! Here is my order:
```json
{"note":"north lane","cogs":[{"id":"KNIGHT-alpha","intent":"intercept",
 "target":[820,300],"face":[900,290],"say":"north"}]}
```
Hope that helps.""")
  check(a.orders.len == 1, "one order")
  check(a.orders[0].intent == intIntercept, "intent survived the fence")
  check(a.orders[0].targetX == 820 and a.orders[0].targetY == 300,
    "target survived the fence")
  check(a.orders[0].say == "north", "say survived the fence")
  check(a.note == "north lane", "note survived the fence")

block cogsAsAnIdKeyedObject:
  let a = parseOne(
    """{"cogs":{"KNIGHT-alpha":{"intent":"hold","target":[500,240]}}}""")
  check(a.orders[0].intent == intHold, "an id-keyed object is accepted")
  check(a.orders[0].targetX == 500, "its target is read")

block aBareOrderObjectWithNoCogsWrapper:
  ## design.md:549-551 lists this among the tolerated shapes: a seat that
  ## commands exactly ONE cog quite reasonably answers with the order itself.
  ## Rejecting it spent a retry and then a whole fallback turn (r1 review N12).
  let a = parseOne("""{"intent":"hold","target":[500,240],"say":"choke"}""")
  check(a.orders.len == 1, "a bare order object must produce one order")
  check(a.orders[0].intent == intHold, "its intent is read")
  check(a.orders[0].targetX == 500 and a.orders[0].targetY == 240,
    "its target is read")
  check(a.orders[0].say == "choke", "its say is read")
  check(a.orders[0].id == Ids[0],
    "the order is assigned to the seat's own cog by position")
  let withNote = parseOne(
    """{"note":"hold the choke","intent":"screen","target":[600,300]}""")
  check(withNote.note == "hold the choke", "a bare order may carry a note")
  check(withNote.orders[0].intent == intScreen, "its intent is read")
  ## A reply with NO order in it is still a parse failure — that is the one
  ## condition the retry and the fallback exist for.
  check(parseFails("""{"note":"thinking about it"}"""),
    "a note with no order must not be read as an order")

block aTargetInsideAWallIsClampedNeverRejected:
  ## design.md:1346-1350's other named case. The parser only bounds the target
  ## to the map box; the walkable snap happens later, in the control layer's
  ## nearestWalkable/nearestOpenCell, so an unreachable order still steers
  ## (tests/test_control.nim's anUnreachableTargetStillMovesEveryTick).
  let corner = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[0,0]}]}""")
  check(corner.orders.len == 1, "a target inside the border wall is accepted")
  check(corner.orders[0].targetX == 0 and corner.orders[0].targetY == 0,
    "it is passed through to the control layer, which snaps it")
  let offMap = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[99999,-5]}]}""")
  check(offMap.orders[0].targetX == 1234 and offMap.orders[0].targetY == 0,
    "an off-map target is clamped to the map box")

block unknownAndHyphenatedIntents:
  check(parseIntent("FALL-BACK") == intFallBack, "hyphens normalise")
  check(parseIntent("  Fall Back ") == intFallBack, "spaces normalise")
  check(parseIntent("charge!") == intIntercept,
    "an unknown intent repairs to intercept, never drops the order")
  for intent in Intent:
    check(parseIntent($intent) == intent, $intent & " must round-trip")

block coordinatesAreRepairedNeverRejected:
  let missing = parseOne("""{"cogs":[{"id":"KNIGHT-alpha"}]}""")
  check(missing.orders[0].targetX == 40 and missing.orders[0].targetY == 329,
    "a missing target falls back to the caller's default (the gate centre)")
  let nan = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","target":["oops","nope"]}]}""")
  check(nan.orders[0].targetX == 40, "a non-numeric target falls back")
  let numeric = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","target":["820.4","300"]}]}""")
  check(numeric.orders[0].targetX == 820, "numeric STRINGS are accepted")
  let offMap = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","target":[99999,-5000]}]}""")
  check(offMap.orders[0].targetX == 1234 and offMap.orders[0].targetY == 0,
    "an off-map target is CLAMPED into the map box")
  let noFace = parseOne("""{"cogs":[{"id":"KNIGHT-alpha","face":null}]}""")
  check(not noFace.orders[0].hasFace, "a null face is no face")

block extraAndMissingEntries:
  let three = parseOne("""{"cogs":[
    {"id":"KNIGHT-alpha","intent":"hold"},
    {"id":"KNIGHT-beta","intent":"screen"},
    {"id":"ARCHER-alpha","intent":"focus"}]}""")
  check(three.orders.len == 1, "extra entries are DROPPED, never fatal")
  check(three.orders[0].intent == intHold, "this seat's own entry is kept")
  let wrongSeat = parseOne(
    """{"cogs":[{"id":"ARCHER-beta","intent":"screen","target":[600,200]}]}""")
  check(wrongSeat.orders[0].fromReply,
    "an entry naming ANOTHER seat is assigned to this hero by position")
  check(wrongSeat.orders[0].intent == intScreen, "its content is used")
  check(parseFails("""{"note":"nothing","cogs":[]}"""),
    "an empty cogs array must raise so the caller can repair it")
  check(parseFails("no json here at all"), "no object must raise")

block runeCapsLandOnRuneBoundaries:
  ## A `say` whose 10th and 11th characters are a 4-byte emoji: the cut must
  ## land on the RUNE boundary and the result must still round-trip through
  ## parseJson and decode as UTF-8.
  let emoji = "\u{1F9DF}"                     ## 4 bytes, 1 rune
  let say = "123456789" & emoji & emoji
  check(say.runeLen == 11, "the fixture must be 11 runes")
  let a = parseOne("""{"cogs":[{"id":"KNIGHT-alpha","say":""" &
    escapeJsonUnquoted(say).escapeJson() & """}]}""")
  check(a.orders[0].say.runeLen <= MaxSayRunes,
    "say is " & $a.orders[0].say.runeLen & " runes, cap is " & $MaxSayRunes)
  check(a.orders[0].say.validateUtf8() < 0,
    "the truncated say must still be valid UTF-8")
  let long = "æ".repeat(300)
  let b = parseOne("""{"note":""" & escapeJsonUnquoted(long).escapeJson() &
    ""","cogs":[{"id":"KNIGHT-alpha"}]}""")
  check(b.note.runeLen == MaxNoteRunes,
    "note is " & $b.note.runeLen & " runes, cap is " & $MaxNoteRunes)
  check(b.note.validateUtf8() < 0, "the truncated note must be valid UTF-8")
  discard parseJson($( %*{"note": b.note} ))

block truncateRunesNeverSplitsACodepoint:
  let text = "æøå\u{1F9DF}ﬁ"
  for limit in 0 .. text.runeLen + 3:
    let cut = text.truncateRunes(limit)
    check(cut.validateUtf8() < 0,
      "truncateRunes(" & $limit & ") produced invalid UTF-8")
    check(cut.runeLen == min(limit, text.runeLen),
      "truncateRunes(" & $limit & ") gave " & $cut.runeLen & " runes")

block theSanitizersHoldTheirContracts:
  check(sanitizeSay("{braces}") == "braces",
    "braces are stripped: the chat stream tells a record from a shout by '{'")
  check(sanitizeNote("two\nlines\r\nhere").find('\n') < 0,
    "newlines collapse so one record stays one line")

block theRecordStaysUnderItsRuneCap:
  var directive = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"focus","target":[900,300],
       "say":"north"}]}""")
  directive.note = "æøå".repeat(200)
  let record = directive.boundedDirectiveRecord(
    1, 7, 0, "KNIGHT-alpha", RoleKnight)
  check(record.runeLen <= MaxDirectiveRunes,
    "the record is " & $record.runeLen & " runes, cap is " &
      $MaxDirectiveRunes)
  check(record.validateUtf8() < 0, "the record must be valid UTF-8")
  let node = parseJson(record)
  check(node["k"].getStr() == "directive", "it must still be a directive")
  check(node["alias"].getStr() == "KNIGHT-alpha", "the alias is carried")
  check(node["role"].getStr() == RoleKnight, "the role is carried")

echo "test_directives: ok"
