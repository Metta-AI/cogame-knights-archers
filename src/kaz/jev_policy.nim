## Jev chooses an ordinary squad directive from one seat's private view.

import std/[json, os, strutils]
import curly

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(ValueError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseJevAction*(view: JsonNode, timeoutSeconds: int): JsonNode =
  let intents = %*{
    "intercept": "Meet and attack the zombie closest to the gate.",
    "hold": "Stand at the selected point and attack nearby zombies.",
    "screen": "Stand between the leader and the gate.",
    "focus": "Attack the zombie nearest the selected point.",
    "fall_back": "Move to the selected point without attacking.",
    "regroup": "Move toward surviving squadmates."
  }
  var points = newJObject()
  var pointDescriptions = newJObject()
  points["self"] = view["you"]["pos"]
  pointDescriptions["self"] = %"Current hero position"
  points["gate"] = view["gate"]["centre"]
  pointDescriptions["gate"] = %"Gate centre"
  for index in 0 ..< view["zombies"].len:
    let zombie = view["zombies"][index]
    let key = "zombie_" & $index
    points[key] = zombie["pos"]
    pointDescriptions[key] = %("Zombie " & $zombie["id"].getInt() &
      ", " & $zombie["gate_px"].getInt() & " px from gate")
  for index in 0 ..< view["squad"].len:
    let hero = view["squad"][index]
    let key = "squad_" & $index
    points[key] = hero["pos"]
    pointDescriptions[key] = %(hero["id"].getStr() & " position")

  let shouts = %*{
    "quiet": "",
    "leader": "leader",
    "hold": "hold gate",
    "fall_back": "fall back",
    "focus": "focus"
  }
  let notes = %*{
    "quiet": "",
    "leader": "Prioritize the zombie nearest the gate.",
    "line": "Hold the gate line and avoid a casualty.",
    "split": "Split targets with the other heroes."
  }
  let questions = %*{
    "intent": {"type": "choice", "instructions":
      "Choose this hero's legal order for the next four seconds.",
      "criteria": intents},
    "target": {"type": "choice", "instructions":
      "Choose the target point for that order from visible positions.",
      "criteria": pointDescriptions},
    "face": {"type": "choice", "instructions":
      "Choose where this hero should face while acting.",
      "criteria": pointDescriptions},
    "say": {"type": "choice", "instructions":
      "Choose a short public shout to coordinate the squad.",
      "criteria": shouts},
    "note": {"type": "choice", "instructions":
      "Choose a private tactical note for the replay and next turn.",
      "criteria": notes}
  }

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $view["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You command one hero in Knights & Archers. Four heroes decide " &
      "simultaneously. Defend the gate; any casualty or breach ends the wave. " &
      "Use only this seat's private observation:\n" & $view,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  let intent = bestChoice(answers["intent"], intents)
  let target = bestChoice(answers["target"], pointDescriptions)
  let face = bestChoice(answers["face"], pointDescriptions)
  let say = bestChoice(answers["say"], shouts)
  let note = bestChoice(answers["note"], notes)
  %*{
    "note": notes[note],
    "cogs": [{
      "id": view["you"]["id"],
      "intent": intent,
      "target": points[target],
      "face": points[face],
      "say": shouts[say]
    }]
  }
