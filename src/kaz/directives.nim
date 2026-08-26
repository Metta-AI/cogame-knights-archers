## The directive schema: what a commander (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal reply is repaired instead of
## rejected.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — that is what makes the bounded-orders test
## in tests/test_control.nim meaningful.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in a
## browser and then fails a strict UTF-8 parser, which is exactly the class of
## bug that makes a replay unreadable to everything except the one viewer that
## happened to be lenient.

import
  std/[json, strutils, unicode],
  sim_types

type
  Intent* = enum
    ## What a hero is being told to do for the next turn. A closed enum: an
    ## unrecognised intent is repaired to `intIntercept`, never dropped, so a
    ## hero is never left unactuated.
    intIntercept = "intercept"
    intHold = "hold"
    intScreen = "screen"
    intFocus = "focus"
    intFallBack = "fall_back"
    intRegroup = "regroup"

  CogOrder* = object
    ## One commanded cog's orders for the next turn.
    cogIndex*: int             ## the live cog this order drives.
    id*: string                ## the hero's anonymous alias, e.g. "KNIGHT-alpha".
    intent*: Intent
    targetX*, targetY*: int    ## clamped into the map box.
    hasFace*: bool
    faceX*, faceY*: int
    say*: string               ## <= MaxSayRunes, sanitized; becomes a SHOUT.
    fromReply*: bool           ## a reply entry really named this cog. False
                               ## means the parser filled it in, and the
                               ## caller repairs it from last turn's directive
                               ## (else holdline's) — never from a default.

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  SquadDirective* = object
    ## One seat's whole order set for one turn.
    note*: string              ## <= MaxNoteRunes; the commander's own line.
    orders*: seq[CogOrder]
    source*: DirectiveSource
    latencyMs*: int

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A cog's shout: capped at MaxSayRunes on a rune boundary FIRST, then run
  ## through the starter's printable-ASCII shout sanitiser. Doing it in that
  ## order means the rune cut never leaves half a codepoint for the ASCII
  ## filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    # Braces are excluded deliberately: the replay chat stream carries the
    # paintball CONTROL records as JSON objects and tells them apart from a
    # cog's shout by a leading '{'. A shout that could start with one would
    # make that discrimination ambiguous.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The commander's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc parseIntent*(text: string): Intent =
  ## Tolerant: case-insensitive, hyphens and spaces normalised to
  ## underscores. Anything still unknown becomes `intercept` — the intent
  ## that always has something useful to do.
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
  for intent in Intent:
    if $intent == key:
      return intent
  intIntercept

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readCoord(node: JsonNode): tuple[ok: bool, value: int] =
  ## One target/face coordinate: an int, a float, or a numeric string.
  ## Anything non-finite or unparseable reports `ok = false` so the caller
  ## can apply its own default rather than inventing a position.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0)
    else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else:
    (false, 0)

proc readPoint(
  node: JsonNode, defaultX, defaultY, maxX, maxY: int
): tuple[given: bool, x, y: int] =
  ## A `[x, y]` pair (an object with x/y keys is accepted too), clamped into
  ## the map box. A missing or non-finite pair reports `given = false` and
  ## returns the caller's default.
  result = (false, defaultX, defaultY)
  if node.isNil or node.kind == JNull:
    return
  var
    rx = (ok: false, value: 0)
    ry = (ok: false, value: 0)
  if node.kind == JArray and node.len >= 2:
    rx = readCoord(node[0])
    ry = readCoord(node[1])
  elif node.kind == JObject:
    rx = readCoord(node{"x"})
    ry = readCoord(node{"y"})
  if not rx.ok or not ry.ok:
    return
  result = (
    true,
    clamp(rx.value, 0, max(0, maxX)),
    clamp(ry.value, 0, max(0, maxY))
  )

proc cogEntries(payload: JsonNode): seq[tuple[id: string, node: JsonNode]] =
  ## The reply's `cogs` collection, accepted either as an ARRAY of objects or
  ## as an OBJECT keyed by cog id (both shapes are things models actually
  ## emit). Entries that are not objects are dropped.
  let node = payload{"cogs"}
  if node.isNil:
    return @[]
  if node.kind == JArray:
    for item in node:
      if item.kind == JObject:
        result.add((item{"id"}.getStr(), item))
  elif node.kind == JObject:
    for key, item in node:
      if item.kind == JObject:
        let id = if item{"id"}.getStr().len > 0: item{"id"}.getStr() else: key
        result.add((id, item))

proc parseSquadDirective*(
  payload: JsonNode,
  commandedIds: seq[string],
  commandedCogs: seq[int],
  defaultX, defaultY, maxX, maxY: int
): SquadDirective =
  ## Turns one parsed reply into a legal directive, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * `note`      truncated to MaxNoteRunes on a rune boundary;
  ## * `cogs`      extra entries dropped, a missing cog left for the caller to
  ##               fill from last turn (or from `holdline`);
  ## * `cogs[].id` matched case-insensitively and suffix-wise; an unmatched
  ##               entry is assigned to the next unclaimed commanded cog BY
  ##               POSITION, which is what rescues a model that invented its
  ##               own naming;
  ## * `intent`    unknown -> intercept;
  ## * `target`    missing / non-finite -> the caller's default (the gate
  ##               centre); otherwise clamped to the map box;
  ## * `face`      same clamp, absent -> none;
  ## * `say`       truncated to MaxSayRunes on a rune boundary, then the
  ##               starter's printable-ASCII shout filter.
  ##
  ## Raises DirectiveError only when NO usable cog entry can be recovered —
  ## that is the one condition the retry and then the scripted fallback exist
  ## for.
  doAssert commandedIds.len == commandedCogs.len
  result.note = sanitizeNote(payload{"note"}.getStr())
  result.source = dsLlm
  var
    claimed = newSeq[bool](commandedIds.len)
    byPosition = 0
    matched = 0
    orders = newSeq[CogOrder](commandedIds.len)
  for i in 0 ..< commandedIds.len:
    orders[i] = CogOrder(
      cogIndex: commandedCogs[i],
      id: commandedIds[i],
      intent: intIntercept,
      targetX: defaultX,
      targetY: defaultY
    )
  for entry in cogEntries(payload):
    var slot = -1
    ## The id is capped at MaxSeatIdRunes RUNES before it is matched, so a
    ## pathological reply cannot make the match loop walk a megabyte.
    let wanted =
      entry.id.strip().truncateRunes(MaxSeatIdRunes).toLowerAscii()
    if wanted.len > 0:
      for i, id in commandedIds:
        if claimed[i]:
          continue
        let mine = id.toLowerAscii()
        if mine == wanted or mine.endsWith(wanted) or wanted.endsWith(mine):
          slot = i
          break
    if slot < 0:
      while byPosition < claimed.len and claimed[byPosition]:
        inc byPosition
      if byPosition >= claimed.len:
        continue                     ## extra entries are dropped, never fatal
      slot = byPosition
    claimed[slot] = true
    inc matched
    orders[slot].fromReply = true
    let node = entry.node
    orders[slot].intent = parseIntent(node{"intent"}.getStr())
    let target = readPoint(node{"target"}, defaultX, defaultY, maxX, maxY)
    orders[slot].targetX = target.x
    orders[slot].targetY = target.y
    let face = readPoint(node{"face"}, 0, 0, maxX, maxY)
    orders[slot].hasFace = face.given
    orders[slot].faceX = face.x
    orders[slot].faceY = face.y
    orders[slot].say = sanitizeSay(node{"say"}.getStr())
  if matched == 0:
    raise newException(DirectiveError, "reply named no commanded cog")
  result.orders = orders

proc directiveRecord*(
  directive: SquadDirective,
  wave, turn, seat: int,
  alias, role: string
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED sim fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  var cogs = newJArray()
  for order in directive.orders:
    var item = %*{
      "id": order.id,
      "intent": $order.intent,
      "target": [order.targetX, order.targetY],
      "say": order.say
    }
    if order.hasFace:
      item["face"] = %[order.faceX, order.faceY]
    else:
      item["face"] = newJNull()
    cogs.add(item)
  %*{
    "k": "directive",
    "wave": wave,
    "turn": turn,
    "seat": seat,
    "alias": alias,
    "role": role,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "note": directive.note,
    "cogs": cogs
  }

proc boundedDirectiveRecord*(
  directive: SquadDirective,
  wave, turn, seat: int,
  alias, role: string
): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## note is the only unbounded-in-practice field, so it is the one that
  ## shrinks; the cut still lands on a rune boundary.
  var trimmed = directive
  result = $trimmed.directiveRecord(wave, turn, seat, alias, role)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    for i in 0 ..< trimmed.orders.len:
      trimmed.orders[i].say = trimmed.orders[i].say.truncateRunes(
        max(0, trimmed.orders[i].say.runeLen - 2))
    result = $trimmed.directiveRecord(wave, turn, seat, alias, role)
  # The loop always converges: with an empty note and empty says the record is
  # a few hundred runes of fixed structure. Never cut the SERIALIZED string —
  # that would emit broken JSON, which is the exact failure the rune rule
  # exists to prevent.
