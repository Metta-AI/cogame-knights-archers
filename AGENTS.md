# Agent operating guide — cogame-knights-archers

Orientation for coding agents working in this repo. The game's rules live in
[docs/RULES.md](docs/RULES.md), the wire in [docs/PROTOCOL.md](docs/PROTOCOL.md)
and the prompt contract in [docs/COMMANDING.md](docs/COMMANDING.md). The design
note this repo was built from is
[docs/plans/2026-08-26-knights-archers-design.md](docs/plans/2026-08-26-knights-archers-design.md).

This file covers the things that are easy to get wrong.

## What this is

A fork of [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf)
(paintbot). Every convention there holds here unless the design note says
otherwise: the 24 Hz tick loop, the Sprite v1 button-mask input, the continuous
integer movement with per-pixel wall masks and slide collision, the arc-cone
attack machinery, the shout channel, the `COWLDKAZ` replay codec with its
per-tick `gameHash` chain, the seat/cog split and the directive decision layer,
the mummy server and its `COGAME_*` runtime contract, the broadcast chrome, and
the emscripten static replay bundle.

The rename is mechanical: `ctf` → `kaz`, `CTF_WIRE` → `KAZ_WIRE`.
`tests/test_viewer.nim` fails the build if any `ctf_`/`CTF_` identifier
survives in `src/`, `client/` or `replay-viewer/`.

## Layout

- `src/knights_archers.nim` — the game entrypoint. **Seed randomisation happens
  HERE, before `config.update`**, so every seed-derived draw follows the final
  seed.
- `src/knights_archers_player.nim` — the thin seat registrar. It sends ONE
  registration chat message (re-sent for ~10 s, because joins are
  slot-sequential) and then only receives.
- `src/kaz/horde.nim` — the zombie list, the spawn schedule, the gate flow
  field, the march, the lunge, the pressure metric.
- `src/kaz/arrows.nim`, `src/kaz/melee.nim` — the two weapons.
- `src/kaz/{decide,directives,control,baselines,llm}.nim` — the per-turn
  decision layer: the parallel batch, the two deadlines, the rate floor, the
  budget guard, tolerant parsing, the rune caps, the fallback ladder, the nav
  grid and the steering.
- `src/kaz/{sim_types,arena,map_art,sim_config,sim_state,roster,sim}.nim` — the
  inherited engine. `sim.nim` imports and RE-EXPORTS all of them, so
  `import kaz/sim` still sees everything.
- `client/`, `replay-viewer/` — the broadcast chrome and the wasm bundle.

## Determinism is the whole contract

The wasm viewer re-derives every frame from the recorded actuator masks and
compares its own `gameHash` against the recorded chain **every tick**. So:

1. **All new sim arithmetic is INTEGER ONLY.** Nim's `int` is 32 bits under
   `--cpu:wasm32`, and a float direction would additionally depend on whichever
   libm the build container shipped. Directions come out of the fixed-point
   `AimUnitX/Y` tables in `sim_types.nim` and out of `horde.intRoot`, never out
   of `sqrt`/`arctan2`. Products that can grow use `int64` intermediates.
2. **The horde is never recorded.** Spawns come from the sim RNG seeded by the
   config seed; marching is a pure function of the installed field. Anything
   that consumes an RNG draw on one side and not the other diverges the chain.
3. **Positions are in MOTION UNITS** (px × `MotionScale`) for zombies and
   arrows: a 384-unit step is exactly 1.5 px/tick with no accumulator and no
   rounding drift.
4. **New hashed fields go at the END** of `gameHash`, and new fields go at the
   END of `SimServer`/`GameConfig`: both ride the flatty replay keyframe
   POSITIONALLY.
5. **Only the sim's own phase machine may change phase.** A test harness that
   calls `resetToLobby` or `startGame` itself records a transition the replay
   cannot re-derive. `tests/helpers.runScripted` follows the phase machine, and
   that is why.

`tests/test_replay.nim` is the guard: it records a real two-wave episode and
re-simulates it with `mismatchQuit = true`, so a single divergent bit fails at
the tick it happens.

## Rune discipline

Every cap in the reply schema is measured in **runes**, and every truncation
lands on a rune boundary (`truncateRunes`). Slicing a string by BYTE index
anywhere on the path to the replay is forbidden: a byte-truncated multi-byte
character renders fine in a browser and then fails a strict UTF-8 parser.
`tests/test_directives.nim` pins it with a 4-byte emoji on the boundary and
`tests/test_replay.nim` runs the whole fixture with a non-ASCII note.

## Two name spaces

Agents see anonymous aliases (`KNIGHT-alpha`, `ARCHER-beta`) and nothing else.
Real policy names live **spectator side only**: the replay config, `roster[]
.name`, the DOM scorebug and `results.names`. `tests/test_identity_privacy.nim`
asserts both directions — a sentinel address must never reach a seat frame, a
shout bubble, an LLM message or a `directive` record, and it MUST appear in the
broadcast frame and the results.

## The viewer chrome is the starter's

`client/chrome_common.js` is **byte-identical** to coworld-ctf's (pinned by
digest in `tests/test_viewer.nim`); `client/broadcast_core.js` differs in
exactly the `KAZ_WIRE` identifier (also pinned); `client/replay_broadcast.html`
is the starter's page with ONE appended game block under a banner comment.

- Do not declare a top-level `function markBeat` (or any other chrome alias) in
  the appended block: a hoisted declaration shadows
  `var markBeat = C.markBeat` and every marker silently becomes an unlabelled
  div (cogame-tandem, 2026-08-23). The game block's builder is `kazBeat`.
- Nothing may be positioned inside the transport band. `relayout()` owns
  `--hudscale`, `--topband` and `--band` on `:root`; the endcard stops at
  `bottom: var(--band, 0px)` and every seek dismisses it.
- Every scrubber beat is a labelled, clickable `<button>`, and there is CSS for
  exactly the five kinds the sim emits and no others.
- Check the scorebug at **360 px**, not at desktop width: the featured-match
  iframe is that wide.

`replay-viewer/{config.nims,static_replay.js,static_replay_worker.js}` and the
wasm entry all come from **coworld-ctf and only coworld-ctf**. The emscripten
link flags and the JS bootstrap are a matched pair — this lineage emits a
NON-modularized module and the Worker waits on `Module.onRuntimeInitialized`.
Splicing another starter's shell onto these flags throws nothing, logs nothing
and hangs on "Loading replay…" forever (cogame-lantern, 2026-08-23).

## Degrade, never hang

The game container does NOT receive `COWORLD_TIMEOUT_SECONDS`. Assume
`episodeTimeoutSeconds` 1200 and settle inside 60 % of it. Every wait is
bounded: the two batch deadlines, the outer per-turn deadline,
`lobbyJoinTimeoutTicks`, mummy's socket timeouts, the 690 s engine stop and the
game-over hold. On a seat's timeout or parse failure the retry is ONE more
batch; on the second failure that seat plays the `phalanx` directive and a
`fallback` record names the cause. **No failure mode leaves a hero unactuated.**

Seats are queried as ONE PARALLEL BATCH per turn (`curly.makeRequests`). This is
a simultaneous-decision game; four sequential calls would quadruple the wall
clock and blow the budget. `tests/test_engine.nim` measures it against a fake
sidecar on localhost.

## Tuning the baseline

`phalanx`'s three numbers are the output of `tools/tune_baselines.nim`, not a
guess. Re-run the sweep after any rules change:

```bash
nim c -d:release --path:src -o:/tmp/tune tools/tune_baselines.nim
/tmp/tune            # the table
/tmp/tune --check    # what CI runs
```

## Running the tests

From the repo ROOT (assets resolve via `data/`), in both modes — CI runs each
file twice and debug catches range/overflow bugs release never sees:

```bash
nim r --hints:off --path:src tests/test_horde.nim
nim r --hints:off -d:release --path:src tests/test_horde.nim
```

`tests/test_perf.nim` is release-only (the `NIM_TESTS_RELEASE_ONLY` repo
variable): a debug build measures the compiler, not the game.

## Things that are NOT here

Deleted with the mechanics they belonged to, not disabled: the hitscan gun and
its jitter/exposure model, spray cans and floor paint, the paint grid and buff,
King of the Hill, the resident/visitor regimes, hearts/flags and capture,
grenades and the barrage, med kits, shields, cardboard barriers, the procedural
map generator and curated pool, the map editor, mapkit, achievements, and
four-team free-for-all. If you find a live reference to one, it is residue —
delete it rather than reviving it.
