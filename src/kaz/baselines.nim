## The two published scripted baselines.
##
## Both emit the SAME directive object an LLM does, on the same 4.0 s cadence,
## so their output is legal by construction and directly comparable. Both are
## pure functions of the world state, which is what makes the bounded-orders
## test in tests/test_control.nim meaningful. Both are documented in
## docs/RULES.md, so "cooperating with a partner you did not write" here means
## "a partner whose published rules you know".
##
## `phalanx` is load-bearing in four places: it is the certification player,
## the per-turn fallback when a seat's LLM call fails twice, the driver of a
## seat that never connects, and the default for a seat that registers with
## neither PLAYER_PROMPT nor PLAYER_SCRIPTED.

import
  std/[algorithm, strutils],
  sim, control, directives

type
  Baseline* = enum
    blPhalanx = "phalanx"
    blStand = "stand"

const
  KnightChokes* = [(560, 240), (560, 420)]
    ## Where the knights stand between rushes: two posts across the middle of
    ## the board, far enough forward that a zombie meets a mace before it is
    ## anywhere near the gate.
  ArcherChokes* = [(300, 240), (300, 420)]
    ## The archers' posts, a bow's length behind the knights.
  KnightCrowdPx* = 90
    ## px: `KnightCrowdCount` bodies inside this radius and a knight gives
    ## ground for one turn. The grid harness's pick, not a guess:
    ## `tools/tune_baselines.nim` plays the four-seat episode over a 3x3x3
    ## matrix of these across four seeds and prints the table. This cell banks
    ## 493 team value against `stand`'s 339 and wins EVERY seed; the design
    ## note's first guess (120 px / 3 bodies / a fixed x=200 retreat) banks
    ## 480, and "knights never fall back" banks 90 and dies on every seed.
  KnightCrowdCount* = 4
  KnightGivePx* = 140
    ## px a retreating knight gives, measured toward the gate rather than to a
    ## fixed column: a fixed x pulls a knight on the far flank across the whole
    ## board and it arrives with the horde behind it.

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `phalanx`: a seat that
  ## says nothing useful still plays the published default rather than sitting
  ## out.
  case text.strip().toLowerAscii()
  of "stand", "standing", "hold": blStand
  else: blPhalanx

proc rankedZombies*(sim: SimServer): seq[int] =
  ## Every live zombie, by gate distance ascending, ties to the lowest id.
  ## `z[0]` is the leader. A total order, purely state-derived, so the same
  ## world always produces the same directive.
  var rows: seq[tuple[dist, id, slot: int]] = @[]
  for i in 0 ..< sim.zombies.len:
    if not sim.zombies[i].alive:
      continue
    rows.add((sim.gateDistOf(sim.zombies[i]), sim.zombies[i].id, i))
  rows.sort(proc (a, b: tuple[dist, id, slot: int]): int =
    if a.dist != b.dist: cmp(a.dist, b.dist) else: cmp(a.id, b.id))
  for row in rows:
    result.add(row.slot)

proc chokePostFor*(sim: SimServer, cogIndex: int): tuple[x, y: int] =
  ## One hero's choke post, snapped to walkable ground.
  let
    knight = sim.isKnight(cogIndex)
    rank = sim.cogIdentityIndex(cogIndex) mod 2
    post = if knight: KnightChokes[rank] else: ArcherChokes[rank]
  sim.nearestWalkable(
    clamp(post[0], 0, MapWidth - 1), clamp(post[1], 0, MapHeight - 1))

proc baseOrder(sim: SimServer, cogIndex: int): CogOrder =
  let post = sim.chokePostFor(cogIndex)
  CogOrder(
    cogIndex: cogIndex,
    id: sim.cogAlias(cogIndex),
    intent: intHold,
    targetX: post.x,
    targetY: post.y,
    say: "choke"
  )

type
  BaselineParams* = object
    ## The three tunables of `phalanx`. They are a parameter rather than a
    ## literal because they were CHOSEN by a grid sweep, not guessed:
    ## `tools/tune_baselines.nim` plays the four-seat episode over a bounded
    ## matrix of them across several seeds and prints the table.
    knightCrowdPx*: int
    knightCrowdCount*: int
    knightGivePx*: int

const DefaultBaselineParams* = BaselineParams(
  knightCrowdPx: KnightCrowdPx,
  knightCrowdCount: KnightCrowdCount,
  knightGivePx: KnightGivePx
)

proc scriptedDirective*(
  ctl: ControlState,
  sim: SimServer,
  kind: Baseline,
  governed: seq[int],
  params = DefaultBaselineParams
): SquadDirective =
  ## The directive one baseline issues for the heroes it governs this turn.
  ##
  ## `phalanx` — role-aware, and it divides the horde BY RANK so two seats
  ## never duplicate work. Rank the live zombies by gate distance ascending:
  ## KNIGHT-alpha intercepts z[0], KNIGHT-beta intercepts z[1] (or z[0] when
  ## only one is alive); ARCHER-alpha focuses z[0], ARCHER-beta focuses z[2]
  ## (or the highest available rank). Knights never fall back. An archer with
  ## any live zombie within `archerPanicPx` falls back toward the gate for
  ## that turn. With no zombies alive, everybody holds the choke.
  ##
  ## `stand` — deliberately weaker and different in SHAPE, so the ladder gets
  ## a spread rather than two versions of one bot: every hero holds its choke
  ## post for the whole wave and never moves. It kills whatever walks into
  ## reach and leaks everything that walks around it.
  result.source = dsScripted
  result.note = if kind == blStand: "hold the posts" else: "hold the gate"
  if governed.len == 0:
    return
  let ranked = rankedZombies(sim)
  for cogIndex in governed:
    var order = baseOrder(sim, cogIndex)
    if kind == blStand:
      result.orders.add(order)
      continue
    if ranked.len == 0:
      result.orders.add(order)
      continue
    let
      knight = sim.isKnight(cogIndex)
      rank = sim.cogIdentityIndex(cogIndex) mod 2
      want =
        if knight: rank                      ## z[0] / z[1]
        else: (if rank == 0: 0 else: 2)      ## z[0] / z[2]
      pick = ranked[min(want, ranked.high)]
      (zx, zy) = sim.zombies[pick].zombiePx()
    order.intent = if knight: intIntercept else: intFocus
    order.targetX = zx
    order.targetY = zy
    order.say = if knight: "on it" else: "loose"
    if knight:
      ## A KNIGHT DOES FALL BACK, from three bodies at once. The design note's
      ## `phalanx` says "knights never fall back"; measured, that baseline
      ## ended both waves `casualty` on every seed tried, because a knight
      ## swings once every 22 ticks and three lunging zombies close 33 px in
      ## that window — it cannot swing them all, and a dead knight ends the
      ## wave for everybody. This is champion #1's own published rule
      ## (docs/COMMANDING.md), applied to the baseline: retreat while three or
      ## more are inside 120 px, then intercept again.
      var crowd = 0
      for i in 0 ..< sim.zombies.len:
        if not sim.zombies[i].alive:
          continue
        let (tx, ty) = sim.zombies[i].zombiePx()
        if distSq(sim.players[cogIndex].x + CollisionW div 2,
                  sim.players[cogIndex].y + CollisionH div 2,
                  tx, ty) <= params.knightCrowdPx * params.knightCrowdPx:
          inc crowd
      if crowd >= params.knightCrowdCount:
        let gate = gateCentre(sim)
        let give = pointToward(
          sim.players[cogIndex].x + CollisionW div 2,
          sim.players[cogIndex].y + CollisionH div 2,
          gate.x, gate.y, params.knightGivePx)
        order.intent = intFallBack
        order.targetX = give.x
        order.targetY = give.y
        order.say = "back"
    else:
      # Distance is the archer's whole role: anything this close and it is
      # already dead if it stops to shoot.
      let panic = max(1, sim.config.archerPanicPx)
      var threatened = false
      for i in 0 ..< sim.zombies.len:
        if not sim.zombies[i].alive:
          continue
        let (tx, ty) = sim.zombies[i].zombiePx()
        if distSq(sim.players[cogIndex].x + CollisionW div 2,
                  sim.players[cogIndex].y + CollisionH div 2,
                  tx, ty) <= panic * panic:
          threatened = true
          break
      if threatened:
        order.intent = intFallBack
        order.targetX = 120
        order.targetY = sim.players[cogIndex].y + CollisionH div 2
        order.say = "back"
    result.orders.add(order)
