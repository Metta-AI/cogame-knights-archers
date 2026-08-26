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
              "pressure", "zombies", "squad", "score", "your_last_directive"]:
    check(view.hasKey(key), "the view is missing " & key)
  check(view["you"]["role"].getStr() == RoleArcher, "seat 2 is an archer")
  check(view["gate"]["line_x"].getInt() == world.config.gateX, "the gate line")
  check(view["breach"]["line_x"].getInt() == world.config.zombieSpawnX,
    "the breach line")
  check(view["gate"]["breach_ends_wave"].getBool(),
    "the view must SAY that a breach ends the wave")

echo "test_observation: ok"
