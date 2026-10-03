## Canonical private complete teacher corpus; shared SDK owns splits and labels.
import std/[json, os, osproc, strutils]
import bitworld/[spriteprotocol, decision_trajectory]
import kaz/[sim, control, directives, baselines, decide, training_capture]

const Variants = ["default", "horde-short", "horde-hard", "horde-tough"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if episodes < 10 or firstSeed < 1: quit("ten episodes and a positive seed are required", 1)
  if variant notin Variants: quit("unknown variant", 1)
  if dirExists(output) or fileExists(output): quit("output already exists", 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  var complete: seq[string]
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    var engine: DecisionEngine
    var prev: seq[InputState]
    var waves = 0
    var decisions = 0
    var lastTurnKey = -1
    var steps = 0
    let capture = newMatchCapture("knights-archers-" & variant & "-" & $seed,
      "source-engine-" & GameVersion, revision, seed)
    while waves < config.maxGames:
      inc steps
      doAssert steps < 120_000
      if game.phase == Lobby and game.players.len == 0:
        for seat in 0 ..< 4:
          discard game.addPlayer("policy-" & $seat, seat, "", trusted = true)
      var inputs = newSeq[InputState](game.players.len)
      if game.phase == Playing:
        engine.ctl.observeHeroes(game)
        let turn = game.gameTicksElapsed() div config.turnTicks
        let key = game.gameIndex * 1_000_000 + turn
        if game.gameTicksElapsed() mod config.turnTicks == 0 and key != lastTurnKey:
          lastTurnKey = key
          let observationHash = game.gameHash()
          discard engine.turn(game, turn, config.maxTicks div config.turnTicks, 0,
            proc(requests: seq[JsonNode], timeoutMs: int): seq[string] =
              raise newException(ValueError, "teacher unexpectedly requested model inference"))
          capture.beginTurn(engine, game, observationHash)
          decisions += 4
          for directive in engine.directives:
            for order in directive.orders:
              if order.say.len > 0: discard game.applyShout(order.cogIndex, order.say)
        for actor in 0 ..< game.players.len:
          for order in engine.directives[game.cogSeat(actor)].orders:
            if order.cogIndex == actor:
              inputs[actor] = decodeInputMask(engine.ctl.compileMask(game, order, actor))
      let before = game.phase
      game.step(inputs, prev)
      var masks = newSeq[uint8](inputs.len)
      for seat, input in inputs: masks[seat] = encodeInputMask(input)
      capture.recordTick(masks, game)
      prev = inputs
      while prev.len < game.players.len: prev.add(InputState())
      if before != Playing and game.phase == Playing:
        engine = initDecisionEngine(game)
        for seat in engine.seats.mitems:
          seat.registered = true
          seat.baseline = blPhalanx
          seat.label = "scripted-phalanx"
      if before == Playing and game.phase != Playing:
        capture.flushTurn(game.tickCount, waves + 1 >= config.maxGames)
      if before != GameOver and game.phase == GameOver:
        inc waves
        game.archiveWave()
        game.gameIndex = waves
    let outcome = parseJson(game.heroResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete and decisions > 0
    capture.finishMatch(game)
    complete.add(capture.trajectory.eventsJsonl())
    runs.add(%*{"seed": seed, "decisions": decisions, "scores": outcome["scores"],
      "team_score": outcome["teamScore"]})
  writePrivate(output / "trajectories.jsonl", complete.join(""))
  writePrivate(output / "manifest.json", pretty(%*{"schema_version": 1,
    "game": "knights-archers", "game_version": "source-engine-" & GameVersion, "engine_version": GameVersion,
    "edition": "source-diagnostic", "variant": variant,
    "source_revision": revision, "teacher": "scripted-phalanx",
    "split_authority": "shared Coworld SDK/application importer by seed_family", "runs": runs}))
  echo episodes, " complete private teacher episodes"
