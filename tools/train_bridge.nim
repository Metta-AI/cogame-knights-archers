## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:knights-archers-train-bridge tools/train_bridge.nim

import std/[json, os, posix]
import bitworld/spriteprotocol
import kaz/[sim, control, directives, baselines, decide, llm]

const
  Variants = ["default", "horde-short", "horde-hard", "horde-tough"]
  Intents = ["intercept", "hold", "screen", "focus", "fall_back", "regroup"]
  Says = ["", "choke", "on it", "loose", "back"]
  Fields = ["intent", "target_x", "target_y", "face", "face_x", "face_y", "say"]
  OperatorPrompt = "Defend the gate with your squad using only the current board and prior shouts."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  result = newJArray()
  for name in Fields:
    var choices = newJArray()
    case name
    of "intent":
      for value in Intents: choices.add(%value)
    of "say":
      for value in Says: choices.add(%value)
    else:
      let high = case name
        of "target_x", "face_x": MapWidth
        of "target_y", "face_y": MapHeight
        else: 1
      for value in 0 .. high: choices.add(%value)
    result.add(%*{"name": name, "choices": choices})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  of JBool: (if node.getBool(): 1.0 else: 0.0)
  else: raise newException(ValueError, "expected numeric observation: " & $node)

proc values(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in Variants: result.add(%(if name == variant: 1 else: 0))
  for name in ["wave", "of", "turn", "turns"]: result.add(%view[name].number())
  for name in ["played_s", "left_s"]: result.add(%view["clock"][name].number())
  let me = view["you"]
  result.add(%(if me["role"].getStr() == "knight": 1 else: 0))
  result.add(%me["alive"].number())
  for value in me["pos"]: result.add(%value.number())
  for name in ["aim", "kills", "reach_px", "cooldown_ticks", "speed_px_s", "ready"]:
    result.add(%me[name].number())
  result.add(%view["gate"]["line_x"].number())
  for value in view["gate"]["centre"]: result.add(%value.number())
  result.add(%view["breach"]["line_x"].number())
  for name in ["alive", "leader_gate_px", "leader_pct", "spawned", "killed",
      "closest_call_px", "spawn_rate_per_s"]:
    result.add(%view["pressure"][name].number())
  let zombies = view["zombies"]
  doAssert zombies.len <= MaxZombies
  for i in 0 ..< MaxZombies:
    if i < zombies.len:
      let zombie = zombies[i]
      result.add(%1)
      for value in zombie["pos"]: result.add(%value.number())
      for name in ["hp", "gate_px", "speed_px_s"]:
        result.add(%zombie[name].number())
      var target = -1
      if zombie["lunging_at"].kind != JNull:
        for seat in 0 ..< 4:
          if zombie["lunging_at"].getStr() == ["KNIGHT-alpha", "KNIGHT-beta",
              "ARCHER-alpha", "ARCHER-beta"][seat]: target = seat
      result.add(%target)
    else:
      for _ in 0 ..< 7: result.add(%0)
  doAssert view["squad"].len == 3
  for actor in view["squad"]:
    result.add(%(if actor["role"].getStr() == "knight": 1 else: 0))
    for value in actor["pos"]: result.add(%value.number())
    for name in ["alive", "kills"]: result.add(%actor[name].number())
    for name in Intents:
      result.add(%(if actor["last_intent"].kind != JNull and
        actor["last_intent"].getStr() == name: 1 else: 0))
    for name in Says:
      result.add(%(if actor["last_say"].kind != JNull and
        actor["last_say"].getStr() == name: 1 else: 0))
  for name in ["team", "team_kills", "waves_cleared", "round_target", "clear_bonus"]:
    result.add(%view["score"][name].number())
  for name in ["your_kills", "your_hits", "your_shots", "team_kills", "zombies_gained"]:
    result.add(%view["last_turn"][name].number())

proc action(order: CogOrder): JsonNode =
  %*{"intent": $order.intent, "target_x": order.targetX,
    "target_y": order.targetY, "face": (if order.hasFace: 1 else: 0),
    "face_x": (if order.hasFace: order.faceX else: 0),
    "face_y": (if order.hasFace: order.faceY else: 0), "say": order.say}

proc hostedDirective(candidate: JsonNode, alias: string): JsonNode =
  var order = %*{"id": alias, "intent": candidate["intent"],
    "target": [candidate["target_x"], candidate["target_y"]],
    "say": candidate["say"]}
  if candidate["face"].getInt() == 1:
    order["face"] = %[candidate["face_x"], candidate["face_y"]]
  %*{"cogs": [order]}

proc decision(view: JsonNode, seat, id: int): JsonNode =
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "knights-archers", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view["turn"],
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": systemPromptFor(view["you"]["role"].getStr())},
      {"role": "user", "content": userMessage(OperatorPrompt, $view)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: knights-archers-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  setCurrentDir(absolutePath(args[0]).parentDir)
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var game: SimServer
  var engine: DecisionEngine
  var views: array[4, JsonNode]
  var teachers: array[4, JsonNode]
  var orders: array[4, CogOrder]
  var prev: seq[InputState]
  var seat = 0
  var id = 0
  var waves = 0
  let protocolFd = dup(1)
  doAssert protocolFd >= 0 and dup2(2, 1) >= 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 4
      var config = defaultGameConfig()
      config.update($variantConfig)
      config.seed = seedOf(request["seed"].getStr())
      game = initSimServer(config)
      prev = @[]
      var inputs: seq[InputState]
      while game.phase != Playing:
        if game.phase == Lobby and game.players.len == 0:
          for actor in 0 ..< 4:
            discard game.addPlayer("policy-" & $actor, actor, "", trusted = true)
        inputs = newSeq[InputState](game.players.len)
        game.step(inputs, prev)
        prev = inputs
        while prev.len < game.players.len: prev.add(InputState())
      engine = initDecisionEngine(game)
      seat = 0
      id = 0
      waves = 0
      for actor in 0 ..< 4:
        views[actor] = parseJson(engine.seatViewJson(game, actor, 0,
          config.maxTicks div config.turnTicks))
        teachers[actor] = action(scriptedDirective(engine.ctl, game,
          blPhalanx, game.commandedCogs(actor)).orders[0])
      engine.markTurn(game)
      response = views[seat].decision(seat, id)
    of "encode":
      doAssert waves < game.config.maxGames
      response = %*{"decision_id": id,
        "values": views[seat].values(variant), "action_heads": heads()}
    of "teacher":
      doAssert waves < game.config.maxGames
      response = %*{"response": $teachers[seat]}
    of "step":
      doAssert waves < game.config.maxGames and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      let directive = parseSquadDirective(candidate.hostedDirective(game.cogAlias(seat)),
        @[game.cogAlias(seat)], @[seat], MapWidth div 2, MapHeight div 2,
        MapWidth, MapHeight)
      doAssert directive.orders.len == 1
      orders[seat] = directive.orders[0]
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      inc id
      inc seat
      var observation: JsonNode
      if seat < 4:
        observation = views[seat].decision(seat, id)
      else:
        while game.phase == Playing:
          engine.ctl.observeHeroes(game)
          var inputs = newSeq[InputState](game.players.len)
          for actor in 0 ..< game.players.len:
            inputs[actor] = decodeInputMask(engine.ctl.compileMask(
              game, orders[game.cogSeat(actor)], actor))
          game.step(inputs, prev)
          prev = inputs
          if game.phase == Playing and game.gameTicksElapsed() mod game.config.turnTicks == 0:
            break
        if game.phase == GameOver:
          inc waves
          game.archiveWave()
          game.gameIndex = waves
        if waves == game.config.maxGames:
          let outcome = parseJson(game.heroResultsJson())
          var scores = newJObject()
          var utilities = newJObject()
          for actor in 0 ..< 4:
            let score = outcome["scores"][actor].number()
            scores[$actor] = %score
            utilities[$actor] = %(max(-1.0, min(1.0, 2.0 * score - 1.0)))
          observation = %*{"kind": "terminal", "scores": scores,
            "utilities": utilities}
        else:
          if game.phase == GameOver:
            while game.phase != Lobby:
              game.step(newSeq[InputState](game.players.len), prev)
            prev = @[]
            while game.phase != Playing:
              if game.phase == Lobby and game.players.len == 0:
                for actor in 0 ..< 4:
                  discard game.addPlayer("policy-" & $actor, actor, "", trusted = true)
              let inputs = newSeq[InputState](game.players.len)
              game.step(inputs, prev)
              prev = inputs
              while prev.len < game.players.len: prev.add(InputState())
            engine = initDecisionEngine(game)
          seat = 0
          let turn = game.gameTicksElapsed() div game.config.turnTicks
          for actor in 0 ..< 4:
            views[actor] = parseJson(engine.seatViewJson(game, actor, turn,
              game.config.maxTicks div game.config.turnTicks))
            teachers[actor] = action(scriptedDirective(engine.ctl, game,
              blPhalanx, game.commandedCogs(actor)).orders[0])
          engine.markTurn(game)
          observation = views[seat].decision(seat, id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.flushFile()
    doAssert dup2(protocolFd, 1) >= 0
    stdout.writeLine($response)
    stdout.flushFile()
    doAssert dup2(2, 1) >= 0
