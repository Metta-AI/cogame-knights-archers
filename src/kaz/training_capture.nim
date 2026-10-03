## Private authoritative squad decisions and one actual Sprite mask per hero/tick.
import std/[base64, json, options]
import bitworld/decision_trajectory
import decide, roster, sim

type
  HeroExecution* = object
    startTick*: int
    observationHash*: uint64
    masks*: string
    hashes*: seq[string]
  MatchCapture* = ref object
    trajectory*: DecisionTrajectory
    pending: bool
    decisions: seq[TurnDecision]
    physical: seq[HeroExecution]

proc newMatchCapture*(episodeId, gameVersion, sourceRevision: string, seed: int): MatchCapture =
  MatchCapture(trajectory: newDecisionTrajectory(episodeId, "knights-archers-" & $seed,
    "knights-archers", gameVersion, sourceRevision))

proc flushTurn*(capture: MatchCapture, endTick: int, terminal = false) =
  if capture.pending:
    for seat, physical in capture.physical:
      doAssert endTick > physical.startTick
      doAssert physical.masks.len == endTick - physical.startTick
      doAssert physical.hashes.len == endTick - physical.startTick
      let issued = capture.decisions[seat]
      var observation = copy(issued.observation)
      observation["execution"] = %*{"start_tick": physical.startTick,
        "end_tick": endTick, "tick_hz": TargetFps, "control_encoding": "sprite-one-u8",
        "seat_input_masks_b64": encode(physical.masks),
        "observation_hash": $physical.observationHash, "post_tick_hashes": physical.hashes}
      capture.trajectory.recordDecision($physical.startTick & "-" & $seat, $seat,
        observation, issued.attempts, issued.selectedAttemptId, issued.executedAction,
        issued.status, terminal, if issued.status == asFallback: some("engine-phalanx") else: none(string))
    capture.pending = false

proc beginTurn*(capture: MatchCapture, engine: DecisionEngine, sim: SimServer,
    observationHash: uint64) =
  ## Hash is before issuing the action; public shouts apply after that observation.
  capture.flushTurn(sim.tickCount)
  capture.pending = true
  capture.decisions = engine.decisions
  capture.physical = newSeq[HeroExecution](engine.decisions.len)
  for physical in capture.physical.mitems:
    physical = HeroExecution(startTick: sim.tickCount, observationHash: observationHash)

proc recordTick*(capture: MatchCapture, masks: seq[uint8], sim: SimServer) =
  if capture.pending:
    doAssert masks.len == capture.physical.len
    for seat, physical in capture.physical.mpairs:
      physical.masks.add(char(masks[seat]))
      physical.hashes.add($sim.gameHash())

proc finishMatch*(capture: MatchCapture, sim: SimServer) =
  capture.flushTurn(sim.tickCount, true)
  let results = parseJson(sim.heroResultsJson())
  results["engine_version"] = %GameVersion
  let status = case results["reason"].getStr()
    of ReasonComplete: esCompleted
    of ReasonDeadline: esTruncated
    else: esFailed
  var participants = newJArray()
  for seat in 0 ..< results["scores"].len:
    participants.add(%*{"seat": $seat, "score": results["scores"][seat],
      "win": results["win"][seat], "kills": results["kills"][seat]})
  capture.trajectory.finish(status, results, participants)
