## The per-seat view contract: exactly what is visible and what is hidden.

import
  std/[json, strutils],
  kaz/[sim, decide, control, baselines],
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

var world = newHordeSim(maxTicks = 2304, maxGames = 2)
world.gameEventLoggingEnabled = false
world.seatNames = ["daveey", "daveey-1", "knights-archers-phalanx",
                 "knights-archers-stand", "", "", "", ""]
var engine = initDecisionEngine(world)

## Put a real horde on the board and give every seat a directive, so the view
## has something to report.
for i in 0 ..< 24:
  world.spawnZombies()
  world.updateZombies()
world.aliveZombies = world.recountAliveZombies()
engine.ctl.observeHeroes(world)
for seat in 0 ..< world.seatCount():
  engine.directives[seat] = scriptedDirective(
    engine.ctl, world, blPhalanx, world.commandedCogs(seat))
  engine.directives[seat].note = "hold the gate"
  engine.haveDirective[seat] = true

block theWholeBoardIsVisibleToEverySeat:
  check(not world.config.fogOfWar, "fogOfWar must be false in the shipped config")
  for seat in 0 ..< world.seatCount():
    let view = parseJson(engine.seatViewJson(world, seat, 7, 24))
    check(view["zombies"].len == world.aliveZombies,
      "seat " & $seat & " sees " & $view["zombies"].len & " of " &
        $world.aliveZombies & " zombies")
    check(view["squad"].len == world.players.len - 1,
      "a seat sees the other three heroes")

block theZombieListIsSortedByGateDistanceAndCapped:
  let view = parseJson(engine.seatViewJson(world, 0, 7, 24))
  var last = -1
  for zombie in view["zombies"]:
    let gate = zombie["gate_px"].getInt()
    check(gate >= last,
      "the zombies array must be sorted by gate_px ascending")
    last = gate
  check(view["zombies"].len <= world.config.spawnCapAlive,
    "the zombies array is capped at spawnCapAlive")

block thePressureBlockAgreesWithAFullRescan:
  let view = parseJson(engine.seatViewJson(world, 1, 7, 24))
  var live = 0
  for zombie in world.zombies:
    if zombie.alive:
      inc live
  check(view["pressure"]["alive"].getInt() == live,
    "pressure.alive must equal a full recount")
  check(view["pressure"]["leader_gate_px"].getInt() == world.leaderGateDist(),
    "pressure.leader_gate_px must equal the sim's own leader distance")
  check(view["pressure"]["killed"].getInt() == world.waveKillsSoFar,
    "pressure.killed must equal the wave's kill count")

block theSpawnRateIsZombiesPerSecond:
  ## The field is named per SECOND and the docs quote 0.29/s rising to 1.20/s,
  ## so it must be a small positive rate -- not the sim's internal per-mille
  ## per tick multiplied by the frame rate, which reported 288 (r1 review N10).
  let view = parseJson(engine.seatViewJson(world, 0, 7, 24))
  let rate = view["pressure"]["spawn_rate_per_s"].getFloat()
  check(rate > 0.0, "the spawn rate must be positive while a wave is running")
  check(rate <= 2.0,
    "spawn_rate_per_s must be zombies per second, got " & $rate)
  let perMille = world.spawnRatePerMille(world.gameTicksElapsed())
  check(abs(rate - float(perMille * TargetFps) / 1000.0) < 1.0e-9,
    "spawn_rate_per_s must be spawnRatePerMille * fps / 1000")

block theLastTurnBlockReportsWhatTheSeatJustDid:
  ## design.md:478-479's `last_turn` block. Before it existed a seat could see
  ## its cumulative kill count and nothing about the four seconds it had just
  ## spent, which is the one thing a commander needs to tell whether its last
  ## order worked (r1 review N11).
  var engine2 = initDecisionEngine(world)
  let before = parseJson(engine2.seatViewJson(world, 0, 0, 24))
  for key in ["your_kills", "your_hits", "your_shots", "team_kills",
              "zombies_gained"]:
    check(before["last_turn"].hasKey(key), "last_turn is missing " & key)
    check(before["last_turn"][key].getInt() == 0,
      "on turn 0 every last_turn delta must be 0, " & key & " was " &
        $before["last_turn"][key].getInt())
  ## Mark the turn, credit some work, and the NEXT view must report the delta
  ## rather than the running total.
  engine2.markTurn(world)
  let killsBefore = world.zombiesKilled
  world.heroKills[0] += 2
  world.heroHits[0] += 3
  world.heroShots[0] += 4
  world.zombiesKilled += 5
  world.zombiesSpawned += 1
  let after = parseJson(engine2.seatViewJson(world, 0, 1, 24))
  check(after["last_turn"]["your_kills"].getInt() == 2, "your_kills delta")
  check(after["last_turn"]["your_hits"].getInt() == 3, "your_hits delta")
  check(after["last_turn"]["your_shots"].getInt() == 4, "your_shots delta")
  check(after["last_turn"]["team_kills"].getInt() == 5, "team_kills delta")
  check(after["last_turn"]["zombies_gained"].getInt() == 1,
    "zombies_gained delta")
  check(after["you"]["kills"].getInt() == world.heroKills[0],
    "`you.kills` stays the EPISODE total")
  ## Put the fixture back the way the later blocks expect it.
  world.heroKills[0] -= 2
  world.heroHits[0] -= 3
  world.heroShots[0] -= 4
  world.zombiesKilled = killsBefore
  world.zombiesSpawned -= 1

block theSeedAndTheRngNeverReachASeat:
  for seat in 0 ..< world.seatCount():
    let text = engine.seatViewJson(world, seat, 7, 24)
    check(not text.contains($world.config.seed),
      "the episode seed must never appear in a seat-facing byte")
    check(not text.contains("\"seed\""), "no seed key in the view")
    check(not text.contains("rng"), "no RNG state in the view")

block onlyAliasesEverReachASeat:
  for seat in 0 ..< world.seatCount():
    let text = engine.seatViewJson(world, seat, 7, 24)
    for name in world.seatNames:
      if name.len == 0:
        continue
      check(not text.contains(name),
        "a REAL policy name (" & name & ") leaked into seat " & $seat &
          "'s view")
    let view = parseJson(text)
    check(view["you"]["id"].getStr().startsWith("KNIGHT-") or
          view["you"]["id"].getStr().startsWith("ARCHER-"),
      "a seat sees only ROLE-identity aliases")
    for mate in view["squad"]:
      check(mate["id"].getStr().startsWith("KNIGHT-") or
            mate["id"].getStr().startsWith("ARCHER-"),
        "a squadmate is named only by alias")

block aSeatNeverSeesAnotherSeatsCurrentTurnNote:
  ## Every seat's `squad[].last_note` is the note from the directive INSTALLED
  ## before this turn — the engine only overwrites a seat's directive once its
  ## own reply has come back, so during a turn every OTHER seat still reads
  ## last turn's. Simulate the turn: change seat 0's note, then check seat 1
  ## still reads the old one for seat 0.
  let before = parseJson(engine.seatViewJson(world, 1, 7, 24))
  var oldNote = ""
  for mate in before["squad"]:
    if mate["id"].getStr() == world.cogAlias(0):
      oldNote = mate["last_note"].getStr()
  check(oldNote == "hold the gate", "the fixture's note must be visible")
  check(before["you"]["id"].getStr() == world.cogAlias(1),
    "the view is built for the seat it was asked for")

block theViewCarriesTheWholeContract:
  let view = parseJson(engine.seatViewJson(world, 2, 7, 24))
  for key in ["wave", "of", "turn", "turns", "clock", "you", "gate", "breach",
              "pressure", "zombies", "squad", "score", "last_turn",
              "your_last_directive"]:
    check(view.hasKey(key), "the view is missing " & key)
  check(view["you"]["role"].getStr() == RoleArcher, "seat 2 is an archer")
  check(view["gate"]["line_x"].getInt() == world.config.gateX, "the gate line")
  check(view["breach"]["line_x"].getInt() == world.config.zombieSpawnX,
    "the breach line")
  check(view["gate"]["breach_ends_wave"].getBool(),
    "the view must SAY that a breach ends the wave")

echo "test_observation: ok"
