## Replay broadcast state channel.
##
## Derives the designed broadcast client's JSON chrome state from the live
## sim. The binary sprite stream stays the board renderer; this module produces
## the parallel TextMessage the broadcast client reads to draw the scorebug,
## kill feed, banners, roster, transport and end-card.
##
## Beat-event derivation mirrors `tools/expand_replay.nim` exactly (per-victim
## death/alive diffs, carrier diffs, capture diffs, phase transitions), so the
## broadcast tells the same story the timeline tool would. Events are derived
## ONE SIM STEP AT A TIME (`stepEvents`) and accumulated by the caller across a
## playback frame, so kill attribution stays exact even at 16x — never
## collapsing a whole span into one ambiguous marker. Attribution still
## degrades honestly to "ambiguous" only on a genuine same-tick multi-kill
## (fidelity rule F7). Kills are never rendered as score (F1); flags have
## exactly HOME/TAKEN/CAPTURED states (F2 — CAPTURED added in GV32, when a
## captured heart retires instead of ending the game); the end-card names
## the tiebreak key and checks a draw before a winner (F3/F4).

import
  std/[algorithm, json, math, strutils],
  sim,
  global   # boardRenderScaleFor: the per-board supersample factor the chrome
           # frame reports so the viewer can convert board px <-> world px

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    alive: seq[bool]
    kills: seq[int]
    deaths: seq[int]
    captures: seq[int]
    carriers: array[Team, int]
    captured: array[Team, bool]
    hillOwned: bool
    hillOwner: Team
    hillTicks: array[Team, int]
    paintCount: array[Team, int]
    hillFlipEmitted: int        ## last ANNOUNCED owner (0 = none, ord+1).
    hillFlipTick: int           ## tick it was announced on; see the throttle.
    hp: seq[int]                ## per cog, for the casualty delta.
    arcTicks: seq[int]          ## per cog, for the `swing` delta.
    gameIndex: int
    startedGame: bool
    # --- knights-archers deltas. Every horde beat is DERIVED from a state
    # delta, so it costs no replay bytes and reads identically live and in
    # replay.
    heroShots: seq[int]         ## per hero, for the `shot` beat.
    heroKills: seq[int]         ## per hero, for the `kill` beat.
    zombiesSpawned: int
    zombiesKilled: int
    minGateDist: int
    lastSpawnBeatTick: int      ## throttle: one `spawn` row per 12 ticks.
    spawnBeatCount: int
    lastLungeBeatTick: int      ## throttle: one `lunge` row per 24 ticks.
    lastCloseCallTick: int
    breachAnnounced: bool
    casualtyAnnounced: int

proc initBroadcastTracker*(): BroadcastTracker =
  ## Returns a fresh, unsynced broadcast tracker.
  result.prevPhase = Lobby
  for team in Team:
    result.carriers[team] = -1

# policyName moved to sim_types.nim (the join path needs it to resolve perk
# groups); re-exported through `import sim`, so every consumer still sees it.

proc slotOf(sim: SimServer, index: int): int =
  ## Returns the stable join slot for a player index, or -1.
  if index >= 0 and index < sim.players.len:
    return sim.players[index].joinOrder
  -1

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  ## Copies the current sim state into the tracker without emitting events.
  tracker.alive.setLen(sim.players.len)
  tracker.kills.setLen(sim.players.len)
  tracker.deaths.setLen(sim.players.len)
  tracker.captures.setLen(sim.players.len)
  tracker.hp.setLen(sim.players.len)
  tracker.arcTicks.setLen(sim.players.len)
  for i, p in sim.players:
    tracker.alive[i] = p.alive
    tracker.kills[i] = p.kills
    tracker.deaths[i] = p.deaths
    tracker.captures[i] = p.captures
    tracker.hp[i] = p.hp
    tracker.arcTicks[i] = p.arcTicksLeft
  for team in sim.teams():
    tracker.carriers[team] = sim.flags[team].carrier
    tracker.captured[team] = sim.flags[team].captured
  tracker.hillOwned = sim.hillOwned
  tracker.hillOwner = sim.hillOwner
  for team in Red .. Blue:
    tracker.hillTicks[team] = sim.hillTicks[team]
    tracker.paintCount[team] = sim.paintCount[team]
  tracker.gameIndex = sim.gameIndex
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.initialized = true
  tracker.heroShots = sim.heroShots
  tracker.heroKills = sim.heroKills
  tracker.zombiesSpawned = sim.zombiesSpawned
  tracker.zombiesKilled = sim.zombiesKilled
  tracker.minGateDist = sim.minGateDist

proc resetFlipWindow(tracker: var BroadcastTracker, sim: SimServer) =
  ## The hillflip throttle's own state, which must NOT be refreshed on every
  ## step (snapshot runs per tick; this window spans HillFlipThrottleTicks of
  ## them). Set on the first frame and after a seek: the current owner counts
  ## as already announced — nothing changed on screen — and the next real
  ## change may fire immediately rather than waiting out a window it never saw.
  tracker.hillFlipEmitted =
    if sim.hillOwned: ord(sim.hillOwner) + 1 else: 0
  tracker.hillFlipTick = -HillFlipThrottleTicks - 1

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots without emitting events, after a seek/loop/skip. The next
  ## `stepEvents` then diffs against this frame, so no phantom beats fire.
  tracker.snapshot(sim)
  tracker.resetFlipWindow(sim)

proc killerThisStep(
  sim: SimServer,
  tracker: BroadcastTracker
): tuple[index: int, ambiguous: bool] =
  ## Returns the single killer's player index for this step, or an ambiguous
  ## marker when two or more players scored a kill on the same tick (fidelity
  ## rule F7 — never guess an attribution the sim can't disambiguate).
  var
    killerIndex = -1
    killerCount = 0
  for i, p in sim.players:
    if i < tracker.kills.len and p.kills > tracker.kills[i]:
      inc killerCount
      killerIndex = i
  if killerCount == 1:
    (killerIndex, false)
  elif killerCount > 1:
    (-1, true)
  else:
    (-1, false)

proc stepEvents*(
  sim: SimServer,
  tracker: var BroadcastTracker,
  events: JsonNode
) =
  ## Appends the beat events produced by the transition from the tracker's last
  ## snapshot to the current sim tick, then advances the tracker.
  ##
  ## EVERY EVENT HERE IS DERIVED from a state delta, so none of them costs a
  ## replay byte and all of them read identically live and in replay. The
  ## vocabulary is the design note's: `phase`, `wavestart`, `spawn`, `swing`,
  ## `shot`, `hit`, `kill`, `lunge`, `closecall`, `casualty`, `breach`,
  ## `waveover`. The five SCRUBBER BEAT kinds — `wavestart`, `closecall`,
  ## `casualty`, `breach`, `waveover` — are the only kinds the viewer's
  ## appended block draws markers for, and it has CSS for exactly those five.
  ## Only meant to be called across a small forward delta (one replay step);
  ## use `resync` after a seek.
  if not tracker.initialized:
    tracker.snapshot(sim)
    tracker.resetFlipWindow(sim)
    return

  let tick = sim.tickCount

  # Phase transitions, and the wave that a Playing transition starts.
  if sim.phase != tracker.prevPhase:
    events.add(%*{"t": tick, "k": "phase", "phase": ($sim.phase).toLowerAscii})
    if sim.phase == Playing:
      events.add(%*{
        "t": tick,
        "k": "wavestart",
        "wave": sim.gameIndex + 1,
        "waves": max(1, sim.config.maxGames)
      })
      tracker.breachAnnounced = false
      tracker.casualtyAnnounced = -1
    if sim.phase == GameOver:
      events.add(%*{
        "t": tick,
        "k": "waveover",
        "wave": sim.gameIndex + 1,
        "waves": max(1, sim.config.maxGames),
        "endRule": sim.endRule,
        "reason": sim.endReason,
        "kills": sim.waveKillsSoFar,
        "teamKills": sim.zombiesKilled,
        "cleared": sim.wavesCleared,
        "ticks": sim.gameTicksElapsed(),
        "closestCallPx": sim.minGateDist
      })

  # The horde's own numbers: what entered, what died, and how close the
  # nearest one came.
  let gained = sim.zombiesSpawned - tracker.zombiesSpawned
  if gained > 0:
    ## THROTTLED to one row per 12 ticks, with a running count: at a saturated
    ## 1.2 zombies/second every arrival would otherwise be a feed row, and the
    ## feed would say nothing but "another one".
    tracker.spawnBeatCount += gained
    if tick - tracker.lastSpawnBeatTick >= 12:
      events.add(%*{
        "t": tick, "k": "spawn", "count": tracker.spawnBeatCount,
        "alive": sim.aliveZombies, "spawned": sim.zombiesSpawned
      })
      tracker.lastSpawnBeatTick = tick
      tracker.spawnBeatCount = 0

  # Per-hero weapon and kill deltas.
  for i, p in sim.players:
    if i < tracker.arcTicks.len and p.arcTicksLeft > 0 and
        tracker.arcTicks[i] == 0:
      events.add(%*{
        "t": tick, "k": "swing", "by": sim.slotOf(i),
        "byAlias": sim.cogAlias(i), "role": sim.roleOf(i),
        "aim": p.arcAimBrads
      })
    if i < tracker.heroShots.len and i < sim.heroShots.len and
        sim.heroShots[i] > tracker.heroShots[i] and not sim.isKnight(i):
      events.add(%*{
        "t": tick, "k": "shot", "by": sim.slotOf(i),
        "byAlias": sim.cogAlias(i), "role": sim.roleOf(i)
      })
    if i < tracker.heroKills.len and i < sim.heroKills.len and
        sim.heroKills[i] > tracker.heroKills[i]:
      events.add(%*{
        "t": tick, "k": "kill", "by": sim.slotOf(i),
        "byAlias": sim.cogAlias(i), "role": sim.roleOf(i),
        # WHICH zombie died, so the feed can say "cuts down Z-118" instead of
        # printing the running team total as if it were an id (r1 review N17).
        "zombie": (if i < sim.heroLastKill.len: sim.heroLastKill[i] else: -1),
        "kills": sim.heroKills[i], "teamKills": sim.zombiesKilled,
        "alive": sim.aliveZombies
      })

  # A zombie charging a hero: the single most watchable moment in the game, and
  # throttled to one row per 24 ticks so a lane of dead does not drown the feed.
  if tick - tracker.lastLungeBeatTick >= 24:
    for zombie in sim.zombies:
      if not zombie.alive or zombie.lungeTarget < 0:
        continue
      events.add(%*{
        "t": tick, "k": "lunge", "zombie": zombie.id,
        "at": sim.cogAlias(zombie.lungeTarget),
        "atSlot": sim.slotOf(zombie.lungeTarget)
      })
      tracker.lastLungeBeatTick = tick
      break

  # The CLOSEST CALL: the one statistic that says how nearly the squad lost a
  # wave it actually won.
  if sim.minGateDist < tracker.minGateDist and
      sim.minGateDist < sim.config.closeCallPx and
      tick - tracker.lastCloseCallTick >= 48:
    tracker.lastCloseCallTick = tick
    events.add(%*{
      "t": tick, "k": "closecall", "gate_px": sim.minGateDist,
      "tick": sim.minGateTick, "alive": sim.aliveZombies
    })

  # One death ends the wave for everybody, and a zombie through the gate does
  # too. Both are announced once.
  if sim.waveCasualty >= 0 and tracker.casualtyAnnounced != sim.waveCasualty:
    tracker.casualtyAnnounced = sim.waveCasualty
    events.add(%*{
      "t": tick, "k": "casualty",
      "who": sim.slotOf(sim.waveCasualty),
      "alias": sim.cogAlias(sim.waveCasualty),
      "role": sim.roleOf(sim.waveCasualty),
      "kills": (if sim.waveCasualty < sim.heroKills.len:
                  sim.heroKills[sim.waveCasualty] else: 0)
    })
  if sim.breachZombie >= 0 and not tracker.breachAnnounced:
    tracker.breachAnnounced = true
    events.add(%*{"t": tick, "k": "breach", "zombie": sim.breachZombie})

  tracker.snapshot(sim)

proc teamPoliciesJson(sim: SimServer, team: Team): JsonNode =
  ## The distinct policy identities seated on one team, in join-slot order.
  ## One entry per policy — a mixed team (PAINTBALL-Doubles: two policies per side)
  ## lists both, so the client can headline and group the roster by policy
  ## instead of collapsing a mixed team to its color.
  result = newJArray()
  var seen: seq[string]
  for p in sim.players:
    if p.team != team:
      continue
    # SPECTATOR SIDE. A squad game's cogs carry anonymous aliases; the real
    # policy identity of the seat that commands them lives in seatNames and
    # is what the scorebug headlines.
    let pol =
      if sim.config.numAgents > 0 and p.seat <= sim.seatNames.high and
          sim.seatNames[p.seat].len > 0:
        policyName(sim.seatNames[p.seat])
      else:
        policyName(p.address)
    if pol notin seen:
      seen.add(pol)
      result.add(%pol)

proc teamStateJson(sim: SimServer, team: Team): JsonNode =
  ## Returns one team's scorebug state: lives, flag state, carrier, progress.
  var
    tags = 0
    tagsTaken = 0
    cogsUp = 0
  for p in sim.players:
    if p.team != team:
      continue
    tags += p.kills
    tagsTaken += p.deaths
    if p.alive:
      inc cogsUp
  ## The heart/flag scorebug fields (`flag`, `carrier`, `prog`) are GONE with
  ## the mechanic they belonged to; the appended viewer block draws four hero
  ## plates instead.
  result = %*{
    "lives": sim.teamLivesRemaining(team),
    "policies": sim.teamPoliciesJson(team)
  }
  if sim.hordeLoadout():
    ## The horde scorebug fields. There is only ONE side of players here —
    ## the squad — so these are the squad's numbers, not a team's.
    result["kills"] = %tags
    result["down"] = %tagsTaken
    result["cogs"] = %cogsUp
  # Per-team handicap for the scorebug badge + its hover breakdown. Present only
  # when the team is actually handicapped, so an unhandicapped team shows no
  # badge. The resolved deltas are computed here (the one place the
  # interpolation lives) so the viewer never re-derives them: `h` is the
  # authored fraction in permille (0..1000); `spd` is max speed as a percent of
  # base; `miss` is the percent of point-blank shots dropped (0..50).
  if sim.config.handicaps[team] > 0:
    result["hcap"] = %*{
      "h": sim.config.handicaps[team],
      "hp": sim.config.hitPointsFor(team),
      "hp0": sim.config.hitPoints,
      "lives": sim.config.livesFor(team),
      "lives0": sim.config.lives,
      "spd": sim.config.maxSpeedFor(team) * 100 div max(1, sim.config.maxSpeed),
      "miss": sim.config.missPermilleFor(team) div 10
    }

proc rosterJson(sim: SimServer): JsonNode =
  ## Returns the per-player roster array keyed by stable join slot.
  result = newJArray()
  for i, p in sim.players:
    let spectatorName =
      if sim.config.numAgents > 0 and p.seat <= sim.seatNames.high and
          sim.seatNames[p.seat].len > 0:
        sim.seatNames[p.seat]
      else:
        p.address
    var item = %*{
      "s": p.joinOrder,
      "team": teamText(p.team),
      "name": spectatorName,
      "pol": policyName(spectatorName),
      "col": int(p.color),
      "alive": p.alive,
      "lives": p.lives,
      "hp": p.hp,
      "carry": p.carryingFlag,
      "k": p.kills,
      "d": p.deaths,
      "cap": p.captures,
      "mk2": p.multiKills2,
      "mk3": p.multiKills3,
      "tk": p.teamKills
    }
    if sim.config.numAgents > 0:
      # Squad-game roster extras (absent on classic wire frames): the cog's
      # anonymous alias, the seat that commands it, and what it stands on.
      item["alias"] = %sim.cogAlias(i)
      item["seat"] = %p.seat
      item["on"] = %(case p.paintUnder
        of puOwn: "own"
        of puEnemy: "enemy"
        of puNone: "none")
    # This seat's perks, wire-named (PerkNames), present only when it has any
    # — so a perk-free game's roster is byte-identical and the scorebug can
    # group a team's perk badges by policy (every seat of one policy shares
    # the same set).
    if p.perks != {}:
      var pk = newJArray()
      for perk in Perk:
        if perk in p.perks:
          pk.add(%perkText(perk))
      item["pk"] = pk
    result.add(item)

const
  FpColumns = 96              ## raycast columns per first-person frame.
  FpMarchStep = 2.0           ## px per wall-march step (fine enough at 1235px).
  FpEntFovMarginBrads = 8.0   ## let a sprite straddling the cone edge still show.
  FpMapCell = 7               ## px per minimap wall-silhouette cell (~176x94 grid).
  FpShotSamples = 14          ## points sampled along a beam. The client draws the
                              ## comet through these, so there must be enough to
                              ## curve a full-range (1050px) beam under
                              ## perspective without bloating the frame.
  FpShotMaxCount = 10         ## most beams per frame (nearest kept), so a chaotic
                              ## firefight cannot balloon the payload.

proc fpMapWallsJson*(sim: SimServer): JsonNode =
  ## Static wall silhouette for the EYES minimap, sent ONCE per viewer. A coarse
  ## row-major grid downsampled from the real wall mask, three states —
  ## 0 = floor, 1 = stone (opaque), 2 = glass (see-through window) — run-length
  ## encoded as a flat [state, count, state, count, …] array. The minimap is a
  ## deliberately un-fogged spectator aid, so terrain is full knowledge.
  let
    gw = (MapWidth + FpMapCell - 1) div FpMapCell
    gh = (MapHeight + FpMapCell - 1) div FpMapCell
    mcx = sim.gameMap.center.x
    mcy = sim.gameMap.center.y
  var
    rle = newJArray()
    runState = -1
    runLen = 0
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let
        sx = min(gx * FpMapCell + FpMapCell div 2, MapWidth - 1)
        sy = min(gy * FpMapCell + FpMapCell div 2, MapHeight - 1)
      var st = 0
      if sim.isWall(sx, sy):
        st = if isArenaWindowPixel(sx, sy, mcx, mcy): 2 else: 1
      if st == runState:
        inc runLen
      else:
        if runLen > 0:
          rle.add(%runState); rle.add(%runLen)
        runState = st
        runLen = 1
  if runLen > 0:
    rle.add(%runState); rle.add(%runLen)
  result = %*{"cell": FpMapCell, "gw": gw, "gh": gh, "w": MapWidth, "h": MapHeight, "rle": rle}

proc bradOffset(a, b: float): float =
  ## Signed smallest angular difference a-b, wrapped to [-128, 128) brads.
  result = a - b
  while result < -float(AimBradsTurn div 2): result += float(AimBradsTurn)
  while result >= float(AimBradsTurn div 2): result -= float(AimBradsTurn)

proc firstPersonJson(sim: SimServer, playerIndex: int): JsonNode =
  ## Builds the selected player's first-person (Wolfenstein-style) raycast view:
  ## per-column perpendicular wall distances plus the billboarded entities the
  ## player can actually see. The main board keeps showing their fogged top-down
  ## POV; this rides alongside as the picture-in-picture inset. Everything here is
  ## derived from the same fog rules the player observes, so the inset never
  ## reveals more than the seat legitimately sees.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return newJNull()
  let
    self = sim.players[playerIndex]
    selfAlive = self.alive
    px = float(self.x + CollisionW div 2)
    py = float(self.y + CollisionH div 2)
    aim = float(self.aimBrads)
    # The inset FOV is literally the player's vision-cone half-angle, so the
    # strip shows exactly the arc they perceive.
    halfFov = float(sim.config.visionConeDeg) * float(AimBradsTurn) / 360.0
    # View depth = VISION reach, not weapon reach: the strip marches as far
    # as the fog lets this seat see (visionRange, 1.5x the gun range —
    # GV34). It used config.gunRange, which stopped being map-wide when
    # GV34 fixed the gun range at 1050 on every map; the strip keeps the
    # half-again sight advantage instead of going blind at the paint line.
    maxRange = float(sim.visionRange())
    radPerBrad = PI / float(AimBradsTurn div 2)

  let
    mcx = sim.gameMap.center.x
    mcy = sim.gameMap.center.y

  # Per-column wall march. Two distances per column: `w` = the first OPAQUE wall
  # (stops the view like stone), `g` = the nearest GLASS pane in front of it.
  # Glass is solid to bullets but see-through (GameVersion 15/16 windows), so the
  # march passes THROUGH it — the client draws it as a translucent pane, not a
  # dead stone face. -1 means "none".
  var cols = newJArray()
  for i in 0 ..< FpColumns:
    let
      frac = (if FpColumns == 1: 0.0 else: float(i) / float(FpColumns - 1))
      # Column 0 = left edge = CCW (+halfFov); column N-1 = right edge = CW.
      colBrad = aim + halfFov - frac * 2.0 * halfFov
      rad = colBrad * radPerBrad
      dx = cos(rad)
      dy = -sin(rad)
      # Fisheye correction factor: project any hit onto the central view axis so
      # a flat wall reads flat, not bowed.
      fish = cos((colBrad - aim) * radPerBrad)
    var
      t = FpMarchStep
      hit = -1
      glass = -1
    while t <= maxRange:
      let
        mx = int(px + dx * t)
        my = int(py + dy * t)
      if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
        break
      if sim.isWall(mx, my):
        if isArenaWindowPixel(mx, my, mcx, mcy):
          # Glass: record the nearest pane, then keep marching — vision (and this
          # strip) sees straight through it to the stone behind.
          if glass < 0:
            glass = int(t * fish)
        else:
          hit = int(t * fish)
          break
      t += FpMarchStep
    if glass >= 0:
      cols.add(%*[hit, glass])
    else:
      cols.add(%hit)

  var ents = newJArray()
  # Paintball beams the seat can see (filled below, only while alive — a ghost's
  # inset is walls-only). Declared here so the frame assembly can read it.
  var shots = newJArray()
  proc addEnt(
    kind, team: string,
    wx, wy: float,
    hp: int,
    carry: bool,
    extra: JsonNode = nil
  ) =
    let
      dx = wx - px
      dy = wy - py
      dist = hypot(dx, dy)
    if dist < 1.0:
      return
    let
      entBrad = arctan2(-dy, dx) / radPerBrad
      off = bradOffset(entBrad, aim)
    if abs(off) > halfFov + FpEntFovMarginBrads:
      return
    # o in [-1, 1]: -1 = left edge (+halfFov), +1 = right edge (-halfFov).
    var e = %*{"k": kind, "team": team, "o": -off / halfFov, "d": int(dist)}
    if hp >= 0:
      e["hp"] = %hp
    if carry:
      e["carry"] = %true
    if not extra.isNil:
      for k, v in extra:
        e[k] = v
    ents.add(e)

  proc addPickup(kind: string, spawn: PickupSpawn) =
    ## A fixed pickup, shown only when present AND inside the seat's real vision
    ## (fog-honest, like every other in-cone billboard).
    if not spawn.present:
      return
    if not sim.fovVisibleAt(playerIndex, spawn.x, spawn.y):
      return
    addEnt("item", "", float(spawn.x), float(spawn.y), -1, false,
           %*{"item": kind})

  # A ghost (dead viewer) sees the whole map's terrain but NO moving entities,
  # so its inset is walls-only — matching the fog contract.
  if selfAlive:
    for j in 0 ..< sim.players.len:
      if j == playerIndex:
        continue
      let other = sim.players[j]
      if not other.alive:
        continue
      if not sim.playerVisibleTo(playerIndex, j):
        continue
      addEnt(
        (if other.team == self.team: "mate" else: "enemy"),
        teamText(other.team),
        float(other.x + CollisionW div 2),
        float(other.y + CollisionH div 2),
        other.hp,
        other.carryingFlag
      )
    # Hearts on their pedestals are billboards; a carried heart rides its
    # carrier (already drawn as that player, tagged carry), so skip it here.
    # A retired heart (GV32 capture or GV33 dead team) is out of play and
    # never drawn.
    for team in sim.teams():
      if sim.flags[team].carrier >= 0 or sim.flags[team].captured:
        continue
      if not sim.flagVisibleTo(playerIndex, team):
        continue
      let f = sim.flags[team]
      addEnt("heart", teamText(team), float(f.x), float(f.y), -1, false)

    # Battlefield pickups the seat can see: corner grenades, center med kits,
    # endzone shields, spray cans. Each renders as a labelled item billboard.
    for sp in sim.grenadeSpawns: addPickup("grenade", sp)
    for sp in sim.medKitSpawns: addPickup("medkit", sp)
    for sp in sim.shieldSpawns: addPickup("shield", sp)
    for sp in sim.sprayPaintSpawns: addPickup("spray", sp)
    for sp in sim.barrierSpawns: addPickup("barrier", sp)

    # --- paintball beams in flight (sim.recentShots; cosmetic, never hashed) ---
    # A hitscan shot has no travelling body, so the board draws it as a COMET: a
    # bright paint head at the impact end with a thin trail fading back to the
    # muzzle (global.nim TracerStages/TrailFalloff/MissStagePenalty). The PiP
    # rebuilds that same comet in 3D, which needs the beam's GEOMETRY in view
    # space — so each shot ships as a POLYLINE of FpShotSamples points, each
    # carrying its bearing offset `o` and radial range `d` exactly like an
    # entity. Perspective then falls out for free: the muzzle end may be far and
    # the impact end near (someone shooting past you) or the reverse (someone
    # shooting at you), and the client just projects each point.
    #
    # Fog-honest, per the inset's contract: a sample is emitted only where this
    # seat can actually SEE that point, and an unseen sample becomes a null hole
    # so the client BREAKS the trail rather than drawing a straight line through
    # fog. A shot fired entirely out of view never appears.
    #
    # Age rides as ticks since firedTick (not wall-clock), so the fade is
    # scrub-safe and replay-deterministic like every other PiP effect.
    for shot in sim.recentShots:
      let
        sx0 = float(shot.x0)
        sy0 = float(shot.y0)
        sx1 = float(shot.x1)
        sy1 = float(shot.y1)
      var
        pts = newJArray()
        anyVisible = false
        nearest = high(int)
      for s in 0 ..< FpShotSamples:
        let
          f = float(s) / float(FpShotSamples - 1)
          wx = sx0 + (sx1 - sx0) * f
          wy = sy0 + (sy1 - sy0) * f
        if not sim.fovVisibleAt(playerIndex, int(wx), int(wy)):
          pts.add(newJNull())
          continue
        let
          dx = wx - px
          dy = wy - py
          dist = hypot(dx, dy)
          entBrad = arctan2(-dy, dx) / radPerBrad
          off = bradOffset(entBrad, aim)
        if abs(off) > halfFov + FpEntFovMarginBrads:
          pts.add(newJNull())
          continue
        anyVisible = true
        nearest = min(nearest, int(dist))
        pts.add(%*{"o": -off / halfFov, "d": int(max(dist, 1.0))})
      if not anyVisible:
        continue
      shots.add(%*{
        "pts": pts,
        "age": sim.tickCount - shot.firedTick,
        # Shooter's TEAM, so the client paints the beam from the same team
        # palette it already uses for cogs and hearts (the board resolves paint
        # through the sprite Palette, which isn't in this module's graph — team
        # is the stable contract and reads identically).
        "team": (block:
          var shotTeam = ""
          for team in sim.teams():
            if shot.color == teamColor(team):
              shotTeam = teamText(team)
              break
          shotTeam),
        # Hits draw bright, misses pre-faded — matching the board.
        "hit": shot.hit,
        # Nearest range, for the payload triage below.
        "near": nearest
      })
    # Cap the payload by keeping the NEAREST beams — those are the ones that read
    # at all; distant ones are a pixel of trail. Never a silent truncation of
    # something visible up close.
    if shots.len > FpShotMaxCount:
      var ordered = shots.getElems()
      ordered.sort(proc (a, b: JsonNode): int =
        cmp(a["near"].getInt, b["near"].getInt))
      var trimmed = newJArray()
      for i in 0 ..< FpShotMaxCount:
        trimmed.add(ordered[i])
      shots = trimmed

  # The seat's own status, so the inset reads as a real HUD (hp / lives / what
  # this soldier is carrying / whether they hold the enemy heart).
  var carriedItems = newJArray()
  if self.hasGrenade: carriedItems.add(%"grenade")
  if self.hasShield: carriedItems.add(%"shield")
  if self.hasSprayPaint: carriedItems.add(%"spray")
  if self.hasBarrier: carriedItems.add(%"barrier")
  let selfJson = %*{
    "hp": self.hp,
    "lives": self.lives,
    "alive": selfAlive,
    "team": teamText(self.team),
    "carry": self.carryingFlag,
    "items": carriedItems,
    # Tick of the seat's latest PAINT hit — every weapon in the game throws
    # paint (gun, grenade, spray can), so all three stamp it. The client fires
    # the visor paint splat when this advances.
    "paintTick": self.paintHitTick
  }

  # Un-fogged tactical map: EVERY player, both hearts, and all present pickups in
  # world coordinates, plus this seat's position + aim + cone geometry. This is
  # the omniscient spectator layer (NOT fog-honest, by design) so the viewer sees
  # where the EYES strip is looking and standing. The strip's `ents` above stay
  # fog-limited; this `map.here` marks the POV and its vision wedge.
  var mapPlayers = newJArray()
  for j in 0 ..< sim.players.len:
    let p = sim.players[j]
    if not p.alive:
      continue
    mapPlayers.add(%*{
      "x": p.x + CollisionW div 2,
      "y": p.y + CollisionH div 2,
      "team": teamText(p.team),
      "self": j == playerIndex,
      "carry": p.carryingFlag
    })
  var mapHearts = newJArray()
  for team in sim.teams():
    mapHearts.add(%*{
      "x": sim.flags[team].x,
      "y": sim.flags[team].y,
      "team": teamText(team),
      "carried": sim.flags[team].carrier >= 0,
      "captured": sim.flags[team].captured
    })
  var mapItems = newJArray()
  proc addMapItem(kind: string, spawn: PickupSpawn) =
    if spawn.present:
      mapItems.add(%*{"x": spawn.x, "y": spawn.y, "item": kind})
  for sp in sim.grenadeSpawns: addMapItem("grenade", sp)
  for sp in sim.medKitSpawns: addMapItem("medkit", sp)
  for sp in sim.shieldSpawns: addMapItem("shield", sp)
  for sp in sim.sprayPaintSpawns: addMapItem("spray", sp)
  for sp in sim.barrierSpawns: addMapItem("barrier", sp)

  let mapJson = %*{
    "w": MapWidth,
    "h": MapHeight,
    "here": %*{
      "x": self.x + CollisionW div 2,
      "y": self.y + CollisionH div 2,
      "aim": self.aimBrads,
      "coneDeg": sim.config.visionConeDeg,
      "bubble": sim.config.visionBubble,
      "alive": selfAlive
    },
    "players": mapPlayers,
    "hearts": mapHearts,
    "items": mapItems
  }

  result = %*{
    "mr": int(maxRange),
    "hfov": halfFov,            ## cone half-angle in brads — the strip's angular half-width.
    "cols": cols,
    "ents": ents,
    "shots": shots,
    "self": selfJson,
    "map": mapJson
  }

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  includeFpMap: bool = false,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil,
  achievementBadges: JsonNode = nil
): string =
  ## Assembles the broadcast chrome frame from the current board state plus the
  ## events accumulated across this playback frame. Board-derived STATE (lives,
  ## flags, roster, verdict) is always present, so even a frame reached by a
  ## seek still hydrates the scorebug and end-card with no events.
  var teams = newJObject()
  for team in sim.teams():
    teams[teamText(team)] = sim.teamStateJson(team)

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    # BOARD pixels per LOGICAL map pixel. Everything the viewer positions with —
    # the letterbox transform, click-to-select, the minimap — lives in board
    # pixels, so a control that has to move a fixed WORLD distance (the viewer's
    # arrow-key pan cell) can only do it by multiplying through this. It cannot
    # be a wire constant: it is per-BOARD, because an oversize map renders at 1x
    # rather than blow the wasm32 viewer's address space (see
    # MaxSupersampledMapPixels), while every normal board renders at RenderScale.
    "bs": boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height),
    "pov": povSlot,
    "teams": teams,
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

  if sim.hordeLoadout():
    ## THE HORDE FRAME. Which wave is playing, and every number the appended
    ## viewer block draws: the pressure bar, the closest-call chalk line, the
    ## four hero plates and the endcard all read from here, so a frame reached
    ## by a SEEK hydrates the whole HUD with no events at all.
    state["wave"] = %(sim.gameIndex + 1)
    state["waves"] = %max(1, sim.config.maxGames)
    state["turnTicks"] = %sim.config.turnTicks
    state["turn"] = %(sim.gameTicksElapsed() div max(1, sim.config.turnTicks))
    state["turns"] = %(
      if sim.config.maxTicks > 0:
        max(1, sim.config.maxTicks div max(1, sim.config.turnTicks))
      else: 0)
    var heroes = newJArray()
    for seat in 0 ..< sim.seatCount():
      heroes.add(%*{
        "seat": seat,
        "alias": sim.cogAlias(seat),
        "role": sim.roleForSeat(seat),
        "name": (
          if seat <= sim.seatNames.high and sim.seatNames[seat].len > 0:
            sim.seatNames[seat]
          else: "player-" & $seat),
        "alive": seat < sim.players.len and sim.players[seat].alive,
        "kills": (if seat < sim.heroKills.len: sim.heroKills[seat] else: 0),
        "hits": (if seat < sim.heroHits.len: sim.heroHits[seat] else: 0),
        "shots": (if seat < sim.heroShots.len: sim.heroShots[seat] else: 0),
        "fellAt": (
          if seat < sim.heroDeathTick.len: sim.heroDeathTick[seat] else: -1)
      })
    state["heroes"] = heroes
    state["horde"] = %*{
      "alive": sim.aliveZombies,
      "spawned": sim.zombiesSpawned,
      "killed": sim.waveKillsSoFar,
      "teamKills": sim.zombiesKilled,
      "leaderGatePx": sim.leaderGateDist(),
      "pressurePct": sim.pressurePct(),
      "spawnGatePx": max(1, sim.spawnGateDist),
      "closestCallPx": sim.minGateDist,
      "closestCallTick": sim.minGateTick,
      "closeCallPx": sim.config.closeCallPx,
      "gateX": sim.config.gateX,
      "breachX": sim.config.zombieSpawnX,
      "wavesCleared": sim.wavesCleared,
      "teamScore": sim.teamScorePermille().float / 1000.0,
      "roundTarget": sim.config.roundTarget,
      "clearBonus": sim.config.clearBonus,
      "spawnRatePerMille": sim.spawnRatePerMille(sim.gameTicksElapsed())
    }

  # The commander lines. This is where a spectator SEES the LLM playing: the
  # directive `note` each seat issued, live and in replay from one source.
  if sim.feedDirectives.len > 0:
    var records = newJArray()
    for record in sim.feedDirectives:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["directives"] = records

  # Resolved perk magnitudes for the scorebug icon tooltips (the sim is the
  # single source of the mods, like the handicap deltas). Fractions are
  # permille ints; present only when some active team actually has perks, so
  # a perk-free game's frame is unchanged.
  var hasPerks = false
  for team in sim.teams():
    if sim.config.perks[team].len > 0:
      hasPerks = true
  if hasPerks:
    state["pmods"] = %*{
      "armorHp": sim.config.perkMods.armorHp,
      "scope": sim.config.perkMods.scopeAim,
      "grenade": sim.config.perkMods.grenadeRange,
      "thruster": sim.config.perkMods.thrusterSpeed,
      "luck": sim.config.perkMods.luckChance,
      "luckDamage": sim.config.perkMods.luckDamage
    }

  # First-person picture-in-picture: the selected seat's raycast view, present
  # only while a player is in POV. The client shows/hides its overlay canvas off
  # `pov >= 0` (like any other state-driven chrome) and redraws from `fp`.
  if povSlot >= 0:
    var povIndex = -1
    for i, p in sim.players:
      if p.joinOrder == povSlot:
        povIndex = i
        break
    if povIndex >= 0:
      let fp = sim.firstPersonJson(povIndex)
      if fp.kind != JNull:
        state["fp"] = fp

  # Full-timeline lead series (sent ONCE per HUD viewer): change-points across
  # the WHOLE episode so the momentum graph draws its full width immediately
  # instead of accumulating to the playhead. Team-keyed so any number of teams
  # graphs: {"teams": [name, …], "pts": [[tick, hillTicks, …], …]} — each point
  # is the tick followed by one CUMULATIVE hill-tick count per team, in `teams`
  # order, and the two-team renderer plots their difference: the hill-tick
  # momentum of the episode. Absent on every later frame — the client caches it.
  if leadSeries.len > 0:
    var teamNames = newJArray()
    if sim.hordeLoadout():
      ## NOT team names: there is one side here. The two series `scanTeamLead`
      ## ships for a horde episode are the squad's cumulative kills and the
      ## leader's pressure, both as PERCENTAGES, and the inherited two-series
      ## renderer plots their difference around its midline -- above the line
      ## the squad is killing faster than the horde is closing, below it the
      ## horde is winning. Shipping ["red", "blue"] here made the graph a
      ## lives-lead tug of war between two teams that do not exist (r1 review
      ## N18); the names only pick the two shading colours.
      teamNames.add(%"kills")
      teamNames.add(%"pressure")
    else:
      for team in sim.teams():
        teamNames.add(%teamText(team))
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": pts}

  # Static minimap wall silhouette for the EYES tactical inset, sent ONCE per
  # viewer (like the lead series). Absent on every later frame — the client
  # caches it and reuses it for the whole match.
  if includeFpMap:
    state["fpmap"] = sim.fpMapWallsJson()

  # Full-timeline flag beats + verdict, shipped alongside the lead series on
  # the same first frame: the steal/return/capture/gameover events the whole
  # match will produce, so the scrubber draws its flag markers and winner cap
  # immediately instead of collecting them as playback passes each one.
  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  # The final game's earned achievements with their focus cogs, shipped on the
  # same lead frame. The client only consults it when the page URL carries
  # ?achievement=<id> (a badge's watch link): it selects the named cog's POV so
  # the viewer opens looking at the receiver.
  if not achievementBadges.isNil and achievementBadges.len > 0:
    state["ach"] = achievementBadges

  # Full-timeline lull spans, shipped alongside the lead series on the same
  # first frame: [[firstTick, lastTick], …] quiet stretches the skip-lulls mode
  # fast-forwards. The client caches them to shade the scrubber.
  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  # The end-card is STATE, not an event: present on every game-over frame so a
  # viewer who seeks straight to the end still sees the verdict. isDraw is read
  # before winner (F4); the tiebreak keys let the card name how it ended (F3),
  # and distinguish a mutual wipe from a dead-even limit (F10).
  if sim.phase == GameOver:
    # Per-team verdict facts, keyed by team name so the end-card generalises
    # to any team count. The legacy redLives/blueLives scalars stay for
    # anything external still reading them.
    var overTeams = newJObject()
    for team in sim.teams():
      overTeams[teamText(team)] = %*{
        "lives": sim.teamLivesRemaining(team),
        "prog": sim.teamFlagProgress(team)
      }
    state["over"] = %*{
      "winner": teamText(sim.winner),
      "draw": sim.isDraw,
      "timeLimit": sim.timeLimitReached,
      "teams": overTeams,
      "redLives": sim.teamLivesRemaining(Red),
      "blueLives": sim.teamLivesRemaining(Blue),
      "redProg": sim.teamFlagProgress(Red),
      "blueProg": sim.teamFlagProgress(Blue)
    }
    if sim.hordeLoadout():
      ## Horde endcard extras: everything the card's four-hero table, its team
      ## line and its per-wave closest-call rows need.
      state["over"]["endRule"] = %sim.endRule
      state["over"]["reason"] = %sim.endReason
      state["over"]["wave"] = %(sim.gameIndex + 1)
      state["over"]["waves"] = %max(1, sim.config.maxGames)
      state["over"]["teamKills"] = %sim.zombiesKilled
      state["over"]["wavesCleared"] = %sim.wavesCleared
      state["over"]["teamScore"] = %(sim.teamScorePermille().float / 1000.0)
      state["over"]["casualty"] = %sim.waveCasualty
      state["over"]["closestCallPx"] = %sim.minGateDist
      var waves = newJArray()
      for i in 0 ..< sim.waveTicksLog.len:
        waves.add(%*{
          "wave": i + 1,
          "ticks": sim.waveTicksLog[i],
          "endRule": (if i < sim.waveEndRuleLog.len: sim.waveEndRuleLog[i]
                      else: EndRuleFullTime),
          "kills": (if i < sim.waveKillsLog.len: sim.waveKillsLog[i] else: 0),
          "closestCallPx": (
            if i < sim.waveClosestLog.len: sim.waveClosestLog[i] else: 0)
        })
      state["over"]["waveLog"] = waves
    # End-segment hold countdown: whole seconds until a looping replay
    # restarts. Present only during the hold, so the end-card can show a
    # "replaying in N" line without ever inventing a countdown after a seek.
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state
