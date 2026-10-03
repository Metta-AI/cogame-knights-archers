## Hosted calls must reach the native sidecar without provider credentials.
include "../src/kaz/llm"

block:
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
  putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
  putEnv("ANTHROPIC_API_KEY", "local-key-must-not-be-used")
  let client = newLlmClient()
  for slot in 0 .. 1:
    let request = client.requestFor("rules", "private view", slot)
    doAssert request.url == "http://127.0.0.1:9100/v1/messages"
    doAssert request.headers["X-Coworld-Player-Slot"] == $slot
    let body = parseJson(request.body)
    doAssert body["model"].getStr() == "anthropic/claude-sonnet-4.6"
    doAssert not body.hasKey("anthropic_version")
    doAssert not body.hasKey("output_config")
  echo "hosted sidecar routing and seat attribution passed"

block:
  delEnv("COWORLD_LLM_ENDPOINT")
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "retired-token")
  putEnv("ANTHROPIC_API_KEY_URI", "file:///retired-key")
  doAssert newLlmClient().disabled
  echo "retired provider credentials cannot enable inference"

block:
  var evidence = newDecisionAttempt("received", "fixture", aoModel)
  evidence.decoder = %*{"temperature": 1, "max_tokens": 16}
  var headers: HttpHeaders
  headers["request-id"] = "actual-provider-request"
  headers["X-Softmax-Llm-Call-Id"] = "a54f294b-2335-42f0-9fb7-980b3f635523"
  headers["X-Provider-Diagnostic"] = "private-received-header"
  evidence.responseEvidence(headers, "actual-received-bytes")
  doAssert evidence.responseHeaders.get()["X-Provider-Diagnostic"] == "private-received-header"
  doAssert evidence.providerRequestId.get() == "actual-provider-request"
  evidence.completionEvidence(%*{"model": "actual-native-model", "stop_reason": "end_turn",
    "sampling_evidence": {"prompt_token_ids": [3], "completion_token_ids": [4],
      "behavior_log_probs": [-0.5], "stop_reason": "eos"}})
  doAssert not evidence.decoder.hasKey("sampling_evidence")
  doAssert evidence.promptTokenIds.get() == @[3]
  doAssert evidence.sampledTokenIds.get() == @[4]
  doAssert evidence.behaviorLogprobs.get() == @[-0.5]
