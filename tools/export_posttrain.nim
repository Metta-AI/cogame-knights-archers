## Export complete scripted Knights & Archers episodes for Metta post-training.
## nim r -d:release --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import bitworld/spriteprotocol
import kaz/[sim, control, directives, baselines, decide, llm]

const
  Variants = ["default", "horde-short", "horde-hard", "horde-tough"]
  OperatorPrompt = "Defend the gate with your squad using only the current board and prior shouts."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown certified variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var
      sim = initSimServer(config)
      engine: DecisionEngine
      orders: array[4, CogOrder]
      prev: seq[InputState]
      waves = 0
      rows: seq[string]
    while waves < config.maxGames:
      if sim.phase == Lobby and sim.players.len == 0:
        for seat in 0 ..< 4:
          discard sim.addPlayer("policy-" & $seat, seat, "", trusted = true)
      var inputs = newSeq[InputState](sim.players.len)
      if sim.phase == Playing:
        engine.ctl.observeHeroes(sim)
        let turn = sim.gameTicksElapsed() div config.turnTicks
        if sim.gameTicksElapsed() mod config.turnTicks == 0:
          var views: array[4, string]
          var proposed: array[4, SquadDirective]
          for seat in 0 ..< 4:
            views[seat] = engine.seatViewJson(sim, seat, turn,
              config.maxTicks div config.turnTicks)
            proposed[seat] = scriptedDirective(engine.ctl, sim,
              blPhalanx, sim.commandedCogs(seat))
          engine.markTurn(sim)
          for seat in 0 ..< 4:
            let directive = proposed[seat]
            let record = directive.directiveRecord(sim.gameIndex + 1,
              turn, seat, sim.cogAlias(seat), sim.roleForSeat(seat))
            let completion = %*{"note": directive.note, "cogs": record["cogs"]}
            let parsed = parseSquadDirective(completion,
              @[sim.cogAlias(seat)], @[seat], MapWidth div 2,
              MapHeight div 2, MapWidth, MapHeight)
            doAssert parsed.orders.len == 1
            doAssert parsed.orders[0].intent == directive.orders[0].intent
            doAssert parsed.orders[0].targetX == directive.orders[0].targetX
            doAssert parsed.orders[0].targetY == directive.orders[0].targetY
            doAssert parsed.orders[0].hasFace == directive.orders[0].hasFace
            doAssert parsed.orders[0].say == directive.orders[0].say
            rows.add($(%*{
              "episode_id": "knights-archers-" & variant & "-" & $seed,
              "seed": "knights-archers-" & variant & "-" & $seed,
              "decision_id": rows.len,
              "prompt": [
                {"role": "system", "content": systemPromptFor(sim.roleForSeat(seat))},
                {"role": "user", "content": userMessage(OperatorPrompt, views[seat])}
              ],
              "completion": [{"role": "assistant", "content": $completion}],
              "game": "knights-archers",
              "action_schema_revision": "kaz-directive-v1"
            }))
            orders[seat] = parsed.orders[0]
            engine.directives[seat] = parsed
            engine.haveDirective[seat] = true
        for cogIndex in 0 ..< sim.players.len:
          let seat = sim.cogSeat(cogIndex)
          inputs[cogIndex] = decodeInputMask(
            engine.ctl.compileMask(sim, orders[seat], cogIndex))
      let before = sim.phase
      sim.step(inputs, prev)
      prev = inputs
      while prev.len < sim.players.len:
        prev.add(InputState())
      if before != Playing and sim.phase == Playing:
        engine = initDecisionEngine(sim)
      if before != GameOver and sim.phase == GameOver:
        inc waves
        sim.archiveWave()
        sim.gameIndex = waves
    let outcome = parseJson(sim.heroResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete and rows.len > 0
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "team_score": outcome["teamScore"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "knights-archers",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-phalanx",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
