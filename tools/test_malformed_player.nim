## Actual native HTTP evidence followed by an invalid socket action frame.
import std/[json, monotimes, options, os, times]
import bitworld/decision_trajectory
import curly, whisky
import kaz/llm
import knights_archers_player

let socket = newWebSocket(getEnv("COWORLD_PLAYER_WS_URL"))
let client = newLlmClient()
var sent = 0
var frames = 0
socket.send(registrationBlob("prompt", "", "malformed-wire-fixture"), BinaryMessage)
while sent < 4:
  inc frames
  doAssert frames <= 1500
  let received = socket.receiveMessage(1000)
  if received.isNone: continue
  let message = received.get()
  if message.kind == BinaryMessage:
    if frames mod 24 == 1:
      socket.send(registrationBlob("prompt", "", "malformed-wire-fixture"), BinaryMessage)
    socket.send(readyBlob(), BinaryMessage)
  elif message.kind == TextMessage:
    let decision = parseJson(message.data)
    if decision["type"].getStr() != "decision": continue
    let view = decision["view"]
    let system = systemPromptFor(view["you"]["role"].getStr())
    let user = userMessage(getEnv("PLAYER_PROMPT"), $view)
    let request = client.requestFor(system, user, decision["slot"].getInt())
    var evidence = newDecisionAttempt($decision["id"].getInt(), "malformed-wire-fixture", aoModel)
    evidence.prompt = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
    evidence.request = parseJson(request.body)
    evidence.decoder = %*{"temperature": client.temperature, "max_tokens": client.maxOutputTokens}
    socket.send($( %*{"type": "attempt_started", "protocol": "kaz.player.v2",
      "id": decision["id"], "training_attempt": attemptEvidenceJson(evidence)}))
    let started = getMonoTime()
    let response = client.curl.post(request.url, request.headers, request.body, 1)
    evidence.latencyMs = some(float((getMonoTime() - started).inMilliseconds))
    evidence.responseEvidence(response.headers, response.body)
    let completion = client.textOf(response)
    doAssert completion.ok and completion.payload.isSome
    evidence.completionEvidence(completion.payload.get())
    evidence.response = %completion.text
    socket.send($( %*{"type": "attempt_response", "protocol": "kaz.player.v2",
      "id": decision["id"], "training_attempt": attemptEvidenceJson(evidence)}))
    socket.send("invalid-final-socket-json")
    inc sent
