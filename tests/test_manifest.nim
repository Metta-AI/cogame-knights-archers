## The manifest template: the seat count everywhere, the closed results schema,
## the docs and protocols in object form, and the bounds the platform's own
## validator applies.

import
  std/[json, os, strutils],
  kaz/sim,
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

let manifest = parseJson(readFile("coworld_manifest_template.json"))

block numAgentsIsFourEverywhere:
  check(manifest["variants"].len == 4,
    "expected four variants, got " & $manifest["variants"].len)
  for variant in manifest["variants"]:
    let cfg = variant["game_config"]
    check(cfg["num_agents"].getInt() == 4,
      "variant " & variant["id"].getStr() & " has num_agents " &
        $cfg["num_agents"].getInt())
    check(variant.hasKey("description") and
          variant["description"].getStr().len > 0,
      "variant " & variant["id"].getStr() & " needs a description")
    check(cfg["roles"].len == 4, "every variant declares four roles")
    check(cfg["slots"].len == 4, "every variant declares four slots")
    check(cfg["players"].len == 4, "every variant names four players")
    check(cfg["tokens"].len == 4, "every variant carries four tokens")
    ## 60 % of the assumed 1200 s episodeTimeoutSeconds is 720.
    check(cfg["wallClockBudgetSeconds"].getInt() <= 720,
      "variant " & variant["id"].getStr() & " overruns 60% of the budget")
  let cert = manifest["certification"]
  check(cert["game_config"]["num_agents"].getInt() == 4,
    "certification.game_config.num_agents must be 4")
  check(cert["players"].len == 4,
    "certification.players must seat exactly four")
  check(cert["game_config"]["players"].len == 4,
    "certification.game_config.players must name four seats")
  ## Every DECLARED player must occupy a certification slot (the raid 0.1.2
  ## `players_missing` scar).
  var declared: seq[string]
  for player in manifest["player"]:
    declared.add(player["id"].getStr())
  for id in declared:
    var seated = false
    for slot in cert["players"]:
      if slot["player_id"].getStr() == id:
        seated = true
    check(seated, "declared player " & id & " occupies no certification slot")

block theUploadContractHolds:
  check(manifest.hasKey("$schema"), "the manifest needs $schema")
  check(manifest["tags"].len >= 3, "the manifest needs at least three tags")
  check(manifest["episode_timeout_minutes"].getInt() == 20,
    "episode_timeout_minutes must be 20")
  check(not manifest.hasKey("version"), "no top-level version")
  check(not manifest.hasKey("replay_viewer"), "no top-level replay_viewer")
  check(not manifest["game"].hasKey("display_name"), "no game.display_name")
  check(not manifest["game"].hasKey("tags"), "tags live top-level only")
  check(manifest["game"]["owner"].getStr().len > 0, "game.owner is required")
  check(manifest["game"]["description"].getStr().len > 0,
    "game.description is required")
  check(manifest["game"]["runnable"]["type"].getStr() == "game",
    "game.runnable.type must be \"game\"")
  check(manifest["game"]["replay_viewer"]["bundle"].getStr() ==
    "static-replay-viewer", "the replay viewer must be the STATIC bundle")

block theImagePlaceholderComesFromTheComposeServiceName:
  let compose = readFile("compose.yaml")
  check(compose.contains("knights_archers:"),
    "the compose service must be underscored so the placeholder derives")
  check(compose.contains("image: coworld-knights-archers:latest"),
    "the compose image must be coworld-knights-archers:latest")
  check(compose.contains("platform: linux/amd64"), "platform must be pinned")
  check(compose.contains("network: host"), "the build must use network: host")
  check(manifest["game"]["runnable"]["image"].getStr() ==
    "{{KNIGHTS_ARCHERS_IMAGE}}",
    "the manifest placeholder must derive from the compose SERVICE name")
  for player in manifest["player"]:
    check(player["image"].getStr() == "{{KNIGHTS_ARCHERS_IMAGE}}",
      "one image, two entrypoints")
    check(player["run"][0].getStr() == "/bin/knights-archers-player",
      "the player entrypoint")
    check(player["resources"]["limits"]["cpu"].getStr() == "1",
      "the bundled player cpu limit minimum is \"1\"")

block theSecretNamespaceEqualsTheGameName:
  let
    name = manifest["game"]["name"].getStr()
    uri = manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr()
  check(name == "knights-archers", "game.name must be the slug")
  check(uri == "secret://coworld/" & name & "/anthropic_api_key",
    "the secret namespace must equal game.name exactly, got " & uri)

block everyArrayPropertyIsBounded:
  let props = manifest["game"]["config_schema"]["properties"]
  for key, prop in props:
    if prop{"type"}.getStr() == "array":
      check(prop.hasKey("minItems") and prop.hasKey("maxItems"),
        "config_schema." & key & " is an array with no minItems/maxItems")
  check(manifest["game"]["config_schema"]["additionalProperties"].getBool() ==
    false, "config_schema must be closed")
  for required in ["tokens", "players"]:
    var found = false
    for item in manifest["game"]["config_schema"]["required"]:
      if item.getStr() == required:
        found = true
    check(found, "config_schema must require " & required)

block theResultsSchemaMatchesTheDocumentKeyForKey:
  var sim = newHordeSim(maxTicks = 240, maxGames = 1)
  let
    document = parseJson(sim.heroResultsJson())
    schema = manifest["game"]["results_schema"]
    props = schema["properties"]
  check(schema["additionalProperties"].getBool() == false,
    "results_schema must be closed")
  for key, _ in document:
    check(props.hasKey(key),
      "heroResultsJson writes " & key & ", which results_schema does not declare")
  for key, _ in props:
    check(document.hasKey(key),
      "results_schema declares " & key & ", which heroResultsJson never writes")
  for key in ["names", "scores", "win", "role", "alias", "kills", "hits",
              "shots", "llmTurns", "fallbackTurns"]:
    check(props[key]["minItems"].getInt() == 4 and
          props[key]["maxItems"].getInt() == 4,
      key & " must be bounded to exactly four seats")
  for key in ["waveTicks", "waveEndRules", "waveKills", "closestCallPx"]:
    check(props[key]["minItems"].getInt() == 1 and
          props[key]["maxItems"].getInt() == 4,
      key & " must be bounded to 1..4 waves")
  check(props["reason"]["enum"].len == 3, "reason is a closed enum of three")
  check(props["endRule"]["enum"].len == 6, "endRule is a closed enum of six")

block everyConfigFieldSimConfigReadsIsDeclared:
  ## The config_schema is what the platform validates a variant against, so a
  ## field the sim reads but the schema does not declare cannot be set.
  let
    props = manifest["game"]["config_schema"]["properties"]
    source = readFile("src/kaz/sim_config.nim")
  for variant in manifest["variants"]:
    for key, _ in variant["game_config"]:
      check(props.hasKey(key),
        "variant sets " & key & ", which config_schema does not declare")
  for key, _ in manifest["certification"]["game_config"]:
    check(props.hasKey(key),
      "the cert fixture sets " & key & ", which config_schema does not declare")
  for key, _ in props:
    if key in ["num_agents", "seed"]:
      continue
    check(source.contains("\"" & key & "\""),
      "config_schema declares " & key & ", which sim_config.update never reads")

block theDocsAndProtocolsAreNonEmptyTextObjects:
  let docs = manifest["game"]["docs"]
  check(docs["readme"]["type"].getStr() == "text", "readme is a text object")
  check(docs["readme"]["value"].getStr().len > 400, "readme is non-empty")
  check(docs["pages"].len == 3, "three doc pages")
  for page in docs["pages"]:
    check(page["id"].getStr().len > 0, "a page needs an id")
    check(page["title"].getStr().len > 0, "a page needs a title")
    check(page["content"]["type"].getStr() == "text", "a page is text")
    check(page["content"]["value"].getStr().len > 200,
      "page " & page["id"].getStr() & " is empty")
  let protocols = manifest["game"]["protocols"]
  for side in ["player", "global"]:
    check(protocols.hasKey(side), "game.protocols must carry " & side)
    check(protocols[side]["type"].getStr() == "text",
      side & " must be an object, not a bare string (the garble scar)")
    check(protocols[side]["value"].getStr().len > 200,
      side & " protocol text is empty")

block theCertFixtureFitsTheCertifyTimeout:
  let cfg = manifest["certification"]["game_config"]
  ## 2 x 600 ticks at 24 fps is 50 s of PLAYBACK, deliberately longer than any
  ## viewer soak window (the ecos 2026-08-23 scar), while fastMode plays it in
  ## a handful of wall seconds.
  check(cfg["maxTicks"].getInt() * cfg["maxGames"].getInt() >= 24 * 30,
    "the fixture must outlast a 30 s viewer soak")
  check(cfg["turnSpacingMs"].getInt() == 0,
    "the fixture pays no rate floor: it never calls an LLM")
  check(cfg["wallClockBudgetSeconds"].getInt() <= 300,
    "the fixture must settle well inside the certify timeout")

block theScaffoldIsPresentAndExecutable:
  for path in ["tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh"]:
    check(fileExists(path), path & " is missing")
    let perms = getFilePermissions(path)
    check(fpUserExec in perms,
      path & " must be committed executable: coworld build requires os.X_OK")
  for path in ["tools/ci/viewer_smoke.mjs", "tools/ci/policies.json",
               ".github/workflows/ci.yml",
               ".github/workflows/coworld-release.yml",
               ".github/workflows/coworld-submit.yml"]:
    check(fileExists(path), path & " is missing")

block thePolicySetIsTwoChampionsAndTwoFillers:
  let policies = parseJson(readFile("tools/ci/policies.json"))
  check(policies.len == 4, "four policies")
  var prompts, scripted, owned = 0
  for policy in policies:
    check(policy["run"].getStr() == "/bin/knights-archers-player",
      "every policy runs the one player entrypoint")
    if policy["env"].hasKey("PLAYER_PROMPT"):
      inc prompts
      check(policy["env"]["PLAYER_PROMPT"].getStr().len > 200,
        policy["name"].getStr() & "'s prompt is too thin to be a strategy")
    if policy["env"].hasKey("PLAYER_SCRIPTED"):
      inc scripted
      check(policy["env"]["PLAYER_SCRIPTED"].getStr() in ["phalanx", "stand"],
        "a scripted policy must name a published baseline")
    if policy.hasKey("player"):
      inc owned
      check(policy["player"].getStr() ==
        "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
        "champion #2 must be owned by daveey-1")
  check(prompts == 2, "TWO LLM prompt champions")
  check(scripted == 2, "two scripted fillers")
  check(owned == 1, "exactly one policy carries the daveey-1 owner")
  check(policies[1]["env"]["PLAYER_PROMPT"].getStr() !=
        policies[0]["env"]["PLAYER_PROMPT"].getStr(),
    "the two champions must have DIFFERENT prompts or they dedupe to one version")

echo "test_manifest: ok"
