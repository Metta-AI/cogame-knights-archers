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
  std/[algorithm, json, strutils],
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

type
  VisibleZombie* = object
    x*, y*, id*, gateDistance*: int
  PolicyView* = object
    cogIndex*: int
    id*: string
    knight*: bool
    heroX*, heroY*, gateX*, gateY*, postX*, postY*, panicPx*: int
    zombies*: seq[VisibleZombie]

proc policyView*(sim: SimServer, cogIndex: int): PolicyView =
  ## Only fields exposed by the ordinary canonical private decision view.
  let post = sim.chokePostFor(cogIndex)
  let gate = gateCentre(sim)
  result = PolicyView(cogIndex: cogIndex, id: sim.cogAlias(cogIndex),
    knight: sim.isKnight(cogIndex), heroX: sim.players[cogIndex].x + CollisionW div 2,
    heroY: sim.players[cogIndex].y + CollisionH div 2, gateX: gate.x, gateY: gate.y,
    postX: post.x, postY: post.y, panicPx: max(1, sim.config.archerPanicPx))
  for rank, slot in rankedZombies(sim):
    if rank >= sim.config.spawnCapAlive: break
    let pos = sim.zombies[slot].zombiePx()
    result.zombies.add(VisibleZombie(x: pos.x, y: pos.y, id: sim.zombies[slot].id,
      gateDistance: sim.gateDistOf(sim.zombies[slot])))

proc policyView*(view: JsonNode): PolicyView =
  let hero = view["you"]
  var seat = -1
  for index, alias in ["KNIGHT-alpha", "KNIGHT-beta", "ARCHER-alpha", "ARCHER-beta"]:
    if hero["id"].getStr() == alias: seat = index
  if seat < 0: raise newException(ValueError, "unknown hero alias")
  result = PolicyView(cogIndex: seat, id: hero["id"].getStr(),
    knight: hero["role"].getStr() == "knight", heroX: hero["pos"][0].getInt(),
    heroY: hero["pos"][1].getInt(), gateX: view["gate"]["centre"][0].getInt(),
    gateY: view["gate"]["centre"][1].getInt(), postX: hero["choke_post"][0].getInt(),
    postY: hero["choke_post"][1].getInt(), panicPx: hero["panic_px"].getInt())
  for zombie in view["zombies"]:
    result.zombies.add(VisibleZombie(x: zombie["pos"][0].getInt(),
      y: zombie["pos"][1].getInt(), id: zombie["id"].getInt(),
      gateDistance: zombie["gate_px"].getInt()))

proc baseOrder(view: PolicyView): CogOrder =
  CogOrder(cogIndex: view.cogIndex, id: view.id, intent: intHold,
    targetX: view.postX, targetY: view.postY, say: "choke")

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

proc scriptedDirective*(view: PolicyView, kind: Baseline,
  params = DefaultBaselineParams): SquadDirective =
  ## The same bounded directive from the ordinary private observation.
  result.source = dsScripted
  result.note = if kind == blStand: "hold the posts" else: "hold the gate"
  var order = baseOrder(view)
  if kind == blPhalanx and view.zombies.len > 0:
    let rank = view.cogIndex mod 2
    let want = if view.knight: rank else: (if rank == 0: 0 else: 2)
    let zombie = view.zombies[min(want, view.zombies.high)]
    order.intent = if view.knight: intIntercept else: intFocus
    order.targetX = zombie.x
    order.targetY = zombie.y
    order.say = if view.knight: "on it" else: "loose"
    if view.knight:
      var crowd = 0
      for target in view.zombies:
        if distSq(view.heroX, view.heroY, target.x, target.y) <= params.knightCrowdPx * params.knightCrowdPx:
          inc crowd
      if crowd >= params.knightCrowdCount:
        let give = pointToward(view.heroX, view.heroY, view.gateX, view.gateY, params.knightGivePx)
        order.intent = intFallBack
        order.targetX = give.x
        order.targetY = give.y
        order.say = "back"
    else:
      for target in view.zombies:
        if distSq(view.heroX, view.heroY, target.x, target.y) <= view.panicPx * view.panicPx:
          order.intent = intFallBack
          order.targetX = 120
          order.targetY = view.heroY
          order.say = "back"
          break
  result.orders.add(order)
