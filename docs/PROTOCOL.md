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
| `ANTHROPIC_API_KEY_URI` | `secret://coworld/knights-archers/anthropic_api_key` |

Routes: `GET /healthz`, `GET /player?slot=N&token=T` (websocket),
`GET /global`, `GET /client/global`, `GET /client/player`, `GET /client/replay`,
`GET /replay-data`, `GET /reward`. A bad slot or token is a 403. `/healthz` and
`/global` keep answering for a bounded shutdown grace after the artifacts are
written.

## The seat socket

A seat receives one binary Sprite v1 frame per tick and sends **no inputs at
all**: every actuator mask is computed server-side by the control layer. The
only thing a seat sends is:

1. **one chat message (`0x81`) carrying its registration**, re-sent for the
   first ~10 s of frames because joins are slot-sequential:

   ```json
   {"type":"register","prompt":"<strategy or empty>",
    "scripted":"phalanx"|"stand"|null,"policy":"<free label>"}
   ```

   The server consumes it as registration, never applies it as a shout and
   never writes the prompt to the replay — only a redacted `register` record.

2. **the Ready packet (`0x85`)** after each received frame. Legitimate here in a
   way it is not for an ordinary client: this seat sends no inputs, so the
   dead-reckoning hazard `fastMode` warns about cannot arise.

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
