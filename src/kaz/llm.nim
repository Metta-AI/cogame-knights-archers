## Native Coworld sidecar requests and private model response evidence.
import std/[json, math, options, os, strutils, tables]
import bitworld/decision_trajectory
import curly
import sim_types, directives

type
  LlmClient* = ref object
    curl*: Curly
    endpoint: string
    model*: string
    temperature*: float
    maxOutputTokens*: int
    disabled*: bool
  LlmCompletion* = object
    ok*: bool
    text*: string
    cause*: string
    payload*: Option[JsonNode]

proc newLlmClient*(): LlmClient =
  result = LlmClient(
    endpoint: getEnv("COWORLD_LLM_ENDPOINT").strip().strip(chars = {'/'}, leading = false),
    model: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "1")),
    maxOutputTokens: max(1, parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", $DefaultMaxOutputTokens))))
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(ValueError, "COWORLD_LLM_TEMPERATURE must be finite within 0..1")
  result.disabled = result.endpoint.len == 0
  if not result.disabled: result.curl = newCurly()

proc requestFor*(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  doAssert slot >= 0 and slot < MaxHeroSeats
  result.url = client.endpoint & "/v1/messages"
  result.headers["content-type"] = "application/json"
  result.headers["anthropic-version"] = "2023-06-01"
  result.headers["X-Coworld-Player-Slot"] = $slot
  result.body = $(%*{"model": client.model, "temperature": client.temperature,
    "max_tokens": client.maxOutputTokens, "system": system,
    "messages": [{"role": "user", "content": user}]})

proc textOf*(client: LlmClient, response: Response): LlmCompletion =
  if response.code in [401, 403]:
    client.disabled = true
    return LlmCompletion(cause: "no_credentials")
  if response.code == 429: return LlmCompletion(cause: "throttled")
  if response.code < 200 or response.code >= 300:
    return LlmCompletion(cause: "transport_error")
  let parsed = parseJsonObject(response.body)
  if not parsed.ok or parsed.node.kind != JObject:
    return LlmCompletion(cause: "parse_error")
  let payload = parsed.node
  result.payload = some(payload)
  for contentBlock in payload["content"]:
    if contentBlock["type"].getStr() == "text":
      result.text.add(contentBlock["text"].getStr())
  if payload["stop_reason"].getStr() == "refusal":
    result.cause = "parse_error"
  elif payload["stop_reason"].getStr() == "max_tokens" and '{' notin result.text:
    result.cause = "parse_error"
  else: result.ok = true

const DefaultOperatorPrompt* = "Defend the gate with your squad using only the current board and prior shouts."

const SystemPrompt* = """
You are ONE hero defending a keep against a horde of the dead, in a top-down
arena 1235 by 659 pixels. The dead walk in at the EAST edge (x=1178) and march
WEST toward your gate (x=40). Two knights and two archers hold the line
together. You are <ROLE>.
KNIGHT: you swing a mace. It reaches 52 pixels in a 90-degree wedge in front of
you and kills a zombie in ONE blow, once every 0.9 seconds. You are the fastest
thing on the field at 66 pixels per second.
ARCHER: you loose arrows. They fly 528 pixels in a straight line at 288 pixels
per second and take TWO hits to kill a zombie, one shot every 0.5 seconds. You
move at 56 pixels per second - slower than a knight, faster than a zombie.
A zombie walks at 36 pixels per second and kills any hero it touches within 26
pixels. Zombies within 90 pixels of a hero stop marching and charge that hero.
THE WAVE ENDS THE INSTANT a zombie reaches the gate, OR a zombie kills ANY hero
- including a hero who is not you. There are no respawns and no second chances.
Your score is your SQUAD'S score: every zombie the four of you kill, plus a big
bonus for surviving the whole 96-second wave. Killing more than your share is
worth nothing if the line breaks.
Every 4 seconds you issue ONE order for yourself. A deterministic controller
executes it for the next 4 seconds: it walks you where you asked around walls,
turns you to face what you asked, and attacks when the blow will land. You never
control motors or the trigger directly.
You can see the whole board: every zombie, every hero, and what the other three
said LAST turn. You cannot see what they are deciding THIS turn - all four of you
decide at the same moment - so use "say" to tell them what you are about to do.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars","cogs":[{"id":"<your own id>",
  "intent":"intercept|hold|screen|focus|fall_back|regroup",
  "target":[x,y],
  "face":[x,y] or null,
  "say":"<=10 chars"}]}
Intents: intercept = go meet the zombie closest to the gate and kill it (a knight
closes to touching range; an archer stops at 300 pixels and shoots);
hold = stand at `target` and kill whatever walks into reach;
screen = put yourself 120 pixels in front of the leading zombie, between it and
the gate; focus = attack the zombie nearest `target`; fall_back = walk to `target`
and do not attack; regroup = move to the middle of your surviving squadmates.
`face` biases your aim. `say` is SHOUTED and every hero hears it.
"""

proc systemPromptFor*(role: string): string =
  ## The fixed system prompt with the ONE `<ROLE>` line filled from the seat's
  ## role. Both champions get the identical prompt otherwise: the knight and
  ## archer paragraphs are both present, and only the line naming which one
  ## this seat is differs.
  SystemPrompt.replace("<ROLE>", (
    if role == RoleKnight: "a KNIGHT" else: "an ARCHER"))

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## view. The view is built server-side from the seat's fog (see decide.nim).
  operatorBlock(operatorPrompt) & viewJson

proc responseEvidence*(attempt: var DecisionAttempt, headers: HttpHeaders, body: string) =
  ## Preserve native metadata before the existing domain completion parser runs.
  attempt.rawResponse = %body
  var receivedHeaders = initTable[string, string]()
  for (key, value) in headers:
    receivedHeaders[key] = value
  attempt.responseHeaders = some(receivedHeaders)
  for key in ["request-id", "x-request-id"]:
    if headers.contains(key):
      attempt.providerRequestId = some(headers[key])
      break
  if headers.contains("X-Softmax-Llm-Call-Id"):
    attempt.platformCallId = some(headers["X-Softmax-Llm-Call-Id"])
  for header in ["X-Coworld-Checkpoint-Sha256", "X-Coworld-Tokenizer-Sha256",
      "X-Coworld-Chat-Template-Sha256"]:
    if headers.contains(header):
      case header
      of "X-Coworld-Checkpoint-Sha256": attempt.modelIdentity = some(headers[header])
      of "X-Coworld-Tokenizer-Sha256": attempt.tokenizerIdentity = some(headers[header])
      else: attempt.chatTemplateSha256 = some(headers[header])

proc completionEvidence*(attempt: var DecisionAttempt, payload: JsonNode) =
  attempt.model = some(payload["model"].getStr())
  attempt.stopReason = some(payload["stop_reason"].getStr())
  if payload.hasKey("usage"):
    attempt.inputTokens = some(payload["usage"]["input_tokens"].getInt())
    attempt.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]: promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]: sampledIds.add(token.getInt())
    attempt.promptTokenIds = some(promptIds)
    attempt.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      for probability in sampling["behavior_log_probs"]: probabilities.add(probability.getFloat())
      attempt.behaviorLogprobs = some(probabilities)
    attempt.stopReason = some(sampling["stop_reason"].getStr())
