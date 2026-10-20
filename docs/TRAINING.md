# Private training trajectories

## Episode rules wording

`promptVariant` selects `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` resolves from an explicit `promptSeed % 5` without
consuming simulation randomness. `heldout-briefing` and `heldout-reference`
are evaluation only. The `knights-archers-rules-v2` bank varies complete arena, weapon, survival,
scoring, control, and visibility explanations. Canonical text now clarifies the
existing personal kill-credit tie-break; action syntax and role facts stay fixed.

Selection lives in the decision engine, outside the positionally serialized
simulation structures. Native players receive it in the private decision
envelope and reject changes during an episode. Teacher and bridge paths use
the same renderer. Private captures retain selection and exact per-attempt
system/user hashes. Bridge observations include `prompt_template` metadata.
Held-out resets require an explicit `evaluation`, `validation`, or `test` split.
Omitted, training, and unrecognized splits reject them.

The source exporter accepts optional `PROMPT_VARIANT PROMPT_SEED` arguments
after the variant. Run it from a clean committed checkout so its recorded source
revision identifies the exported code. It rejects held-out wordings. Mixed exports cycle five training wordings between games. The original combined
private trajectory stream and source manifest are retained. Episode IDs include
selected wording and prompt seed; seed-family IDs remain independent of both.
Use `tools/check_training_replay.nim REPLAY TRAJECTORY` to re-simulate every
tick and compare every captured actuator mask and state hash. No automatic
labels or split assignment are added; independent review remains required.

```sh
export_posttrain PRIVATE_OUTPUT 10 1 default mixed 3
python3 tools/test_prompt_games.py BRIDGE ORIGINAL_BRIDGE
```

The complete-game comparison covers all published variants, every wording,
both bridge modes, and the original canonical renderer. Deterministic parity
does not establish improved model play or prevention of training collapse.

Production players, scripted teachers, and `--language` bridge decisions use the same private hero view and directive parser. Numeric bridge actions remain a separate experimental task.

Build and exercise both bridge modes:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/knights-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/knights-bridge
/tmp/knights-bridge coworld_manifest_template.json default --language
```

Omit `--language` for the 537-feature numeric task with seven action heads. Metta RL and native PufferLib consumers use four players and a finite timestep limit. The language mode uses production JSON directives and explicit `text_action` inference mode.

The game owns acceptance, fallback, and executed actions. Player evidence cannot assert teacher or human provenance. Model replies must independently parse to the submitted directive. Engine repairs exclude that attempt from targets.

Native inference uses only `COWORLD_LLM_ENDPOINT`; retired Anthropic and Bedrock credentials cannot enable a request. Native players send private attempt-start and received-response frames before their final action. The game retains timeout, malformed response, rejected, and sampled attempts. Exact received header maps and provider request IDs remain private. Sampling outputs are recorded as evidence, never as unsent decoder controls. Platform call IDs come from `X-Softmax-Llm-Call-Id`. Local fixture IDs are not hosted archive evidence. Socket receipt timestamps enforce the exact engine deadline, including while public views render. HTTP transport timeouts round upward to whole seconds without extending engine acceptance or retry budgets.

Set `COGAME_SAVE_TRAJECTORY_URI` for private capture. The reviewed runtime must supply `COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`. The game version is the published package version; `outcome.engine_version` identifies internal rules. Release uploads remain blocked until that runtime is deployed and verified.

Each decision records its pre-action view, parsed proposal, selected attempt, executed directive, and actual execution. Physical evidence uses `sprite-one-u8`: one Sprite mask per hero per tick, exclusive tick bounds, 24 Hz, and every post-tick hash. The binary replay independently validates those masks and hashes. Public shouts apply before movement and remain hashed game state.

Compile `tools/export_posttrain.nim` and run:

```sh
export_posttrain PRIVATE_OUTPUT 10 1 default
```

The exporter writes exclusive private files containing complete canonical trajectories and a manifest. It labels this corpus `source-diagnostic`, with `source-engine-1` as its edition and the immutable source revision. It does not claim deployed package parity. Use the shared Coworld SDK/application importer to validate episodes and derive labels and splits. Seed families are `knights-archers-SEED` across variants. No game-owned split algorithm exists.

Teacher prompts and actions consume only the ordinary private view. Hidden seed/RNG state never enters policy input. Corpora require content review before training; synthetic native fixtures do not qualify real hosted sampling or reinforcement-learning provenance.

Existing pre-modernization exports and optimizer reports remain historical evidence at source `a0c9f1c1786b6a70b502a6acb1d246da563f26d4`. They do not certify this source edition or deployed runtime. Fresh canonical exports use new directories.

The existing native HTTP-fixture harness exercises mixed wording, retries,
provider failures, and private capture using its short protocol episode:

```sh
python3 tools/test_native_trajectory.py GAME PLAYER PRIVATE_OUTPUT
check_training_replay PRIVATE_OUTPUT/accepted/replay.bitreplay PRIVATE_OUTPUT/accepted/trajectory.jsonl
```

These fixtures verify request handling and captured physical execution.
They do not measure model quality or resistance to training collapse.
