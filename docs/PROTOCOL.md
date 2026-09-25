# Wire protocol — knights-archers

Inherited from `coworld-ctf` (the Sprite v1 protocol over websockets) with the
horde's own record vocabulary on top.

## Runtime contract

The game container reads the standard `COGAME_*` environment:

| variable | meaning |
|---|---|
| `COGAME_CONFIG_URI` | the episode's game config JSON |
| `COGAME_RESULTS_URI` | where the results document is written |
| `COGAME_SAVE_REPLAY_URI` | where the `.replay` bytes are written |
| `COGAME_PLAYER_FAILURE_URI` | where a no-show seat is reported |
| `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream |
| `COGAME_METRICS_URI` | per-episode metrics |
| `COGAME_HOST` / `COGAME_PORT` | the listener |

Routes: `GET /healthz`, `GET /player?slot=N&token=T` (websocket),
`GET /global`, `GET /client/global`, `GET /client/player`, `GET /client/replay`,
`GET /replay-data`, `GET /reward`. A bad slot or token is a 403. `/healthz` and
`/global` keep answering for a bounded shutdown grace after the artifacts are
written.

## The seat socket

A seat receives one binary Sprite v1 frame per tick and sends no button inputs:
every actuator mask is computed server-side by the control layer. The seat also
exchanges private JSON decision frames with the game:

1. **one chat message (`0x81`) carrying its registration**, re-sent for the
   first ~10 s of frames because joins are slot-sequential:

   ```json
   {"type":"register","kind":"scripted"|"prompt"|"jev",
    "scripted":"phalanx"|"stand"|null,"policy":"<free label>"}
   ```

   The server consumes it as registration, never applies it as a shout and
   writes only the policy label and kind to the replay. The operator prompt
   and model credentials stay in the player container.

2. **the Ready packet (`0x85`)** after each received Sprite frame. Legitimate here in a
   way it is not for an ordinary client: this seat sends no inputs, so the
   dead-reckoning hazard `fastMode` warns about cannot arise.

3. **one text decision frame** for each prompt or Jev seat at a turn boundary:

   ```json
   {"type":"decision","protocol":"kaz.player.v2","id":100000,
    "slot":0,"attempt":1,"timeout_ms":4500,"view":{...}}
   ```

   The `view` is the existing private `seatViewJson`: own hero, visible horde,
   squad positions and last-turn messages, gate, pressure, and score. It has no
   episode seed, future spawns, other policy prompts, or current-turn orders.
   The game builds all four views from one pre-action state. It sends each
   model player's view before waiting for any action. Scripted seats use the
   game baseline. Each model player returns a text frame with its directive:

   ```json
   {"type":"action","protocol":"kaz.player.v2","id":100000,
    "source":"llm","action":{"note":"hold the line",
    "cogs":[{"id":"KNIGHT-alpha","intent":"intercept",
    "target":[820,300],"face":[900,290],"say":"north"}]}}
   ```

   With no credential, a model player returns `source:"fallback"` and
   `cause:"no_credentials"`. The game validates and repairs directives, then
   compiles them to actuator masks. Missing or invalid replies get one retry
   and then the game-owned `phalanx` fallback. Both attempts share the turn's
   seven-second budget. The replay records the accepted directive and masks,
   never a model request or secret.

Every hero, every zombie and every arrow appears in every seat's frame:
`fogOfWar` is false in every shipped variant.

## The replay

A binary `COWLDKAZ` file: magic, format version, game name/version, the resolved
config JSON (seed, `mapSpec`, roster, every tuning field), then joins, per-hero
input-mask changes, chat records and **one `gameHash` per tick**. The whole
horde is re-derived from the seeded RNG at playback and never recorded, which is
why the file stays around 350 KB and why a hash mismatch is a real integrity
signal.

Chat records:

| `k` | fields |
|---|---|
| `register` | `seat`, `alias`, `role`, `policy` (≤ 48 runes), `kind`, `baseline` |
| `directive` | `wave`, `turn`, `seat`, `alias`, `role`, `source`, `latency_ms`, `note` (≤ 160 runes), `cogs[]` |
| `fallback` | `wave`, `turn`, `seat`, `attempt`, `cause`, `detail` (≤ 200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `result` | the whole results document, once at episode end |

Every recorded string is truncated on **rune** boundaries, never bytes.
`tools/replay_summary.py` decodes all of it with the Python standard library.

## Derived broadcast events

Diffed from state, so they cost no replay bytes and read identically live and in
replay: `phase`, `wavestart`, `spawn`, `swing`, `shot`, `kill`, `lunge`,
`closecall`, `casualty`, `breach`, `waveover`. The five scrubber beat kinds are
`wavestart`, `closecall`, `casualty`, `breach`, `waveover`.

## Results

Written to `COGAME_RESULTS_URI`; it must equal the manifest's `results_schema`
key for key (that schema is `additionalProperties: false`).

```json
{"names": [...], "scores": [...], "win": [...], "role": [...], "alias": [...],
 "kills": [...], "hits": [...], "shots": [...],
 "llmTurns": [...], "fallbackTurns": [...],
 "teamScore": 0.611, "teamKills": 93, "wavesCleared": 1,
 "waveTicks": [...], "waveEndRules": [...], "waveKills": [...],
 "closestCallPx": [...],
 "reason": "complete", "endRule": "casualty",
 "games": 2, "finalTick": 3111, "seed": 679961}
```

The ten seat-indexed arrays have exactly `num_agents` entries. `reason` is one
of `complete`, `deadline`, `fault`; `endRule` one of `full_time`, `breach`,
`casualty`, `wall_clock`, `sim_fault`, `host_error`.
