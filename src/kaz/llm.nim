## Claude-backed squad command. A policy is just a prompt: the game server
## composes the seat's fogged view plus that seat's PLAYER_PROMPT and asks
## Claude what its cogs do for the next 4.5 seconds.
##
## Ported from `cogame-bullwhip/src/bullwhip/llm.nim`, behaviour for
## behaviour — the credential ladder, the Bedrock model rotation, the
## fence-tolerant JSON extraction and the rune-boundary truncation are all
## that file's, because they are all scar tissue from real hosted failures.
##
## Paintball is a SIMULTANEOUS-decision game, so both seats' calls go out as
## ONE parallel batch per turn (`curly.makeRequests`). Seats are never queried
## sequentially: that is what keeps 40 turns inside the wall-clock budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim_types, directives

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again (paintball round 2, 2026-08-25).

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "knights-archers llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. Haiku first, then sonnet-4-5 — `tryNextBedrockModel` advances on a
  ## 401/403 "Model access is denied" and on a 429.
  ##
  ## `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate: it
  ## times out on every sidecar call (cogame-raid round 2, 2026-08-23), and one
  ## throttle cascading into that cascades into a whole episode of scripted
  ## fallbacks.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "knights-archers llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "knights-archers llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "knights-archers llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" below: "LLM provider is unavailable".
    echo "knights-archers llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

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
