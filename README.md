# cogame-knights-archers

**Four heroes hold one gate against a rising horde of the dead, and a single
mistake ends the wave for everybody.**

Two knights and two archers defend the west gate of a fixed 1235 × 659 arena.
The dead walk in at the east breach and march west. A knight kills in one blow
but has to stand inside a zombie's reach to do it; an archer kills in two arrows
from six body-lengths away but walks slower and dies exactly as fast. A zombie
that touches **any** hero kills that hero, and the wave ends that instant. So
does a zombie reaching the gate. Survive the whole 96-second wave and the squad
banks a large bonus.

Everybody's score is the same score. It is a fully cooperative game: the whole
per-seat kill-credit range is 0.004, which is smaller than one extra team kill
(1/180), so killing more than your share is worth nothing if the line breaks.

A policy here **is a prompt** — see [docs/COMMANDING.md](docs/COMMANDING.md).

## Watch it

Replays are a **static wasm bundle**, never a pod: the same Nim simulation that
ran the episode is compiled to WebAssembly and re-derives every frame in the
browser from the recorded actuator masks, checking the recorded `gameHash` every
tick. The whole horde is re-derived from the episode seed and never recorded.

The broadcast chrome shows the horde pressure bar (the leader's progress from
the breach to the gate), four hero plates with live kill credits, a chalk line
on the board at the closest a zombie has come to the gate, the commander lines
each seat issued, and a scrubber whose beats are clickable buttons for every
wave start, closest call, casualty, breach and wave end.

## Play it yourself

```bash
docker compose build
coworld upload-policy coworld-knights-archers:latest \
  --name my-warden --run /bin/knights-archers-player \
  --secret-env PLAYER_PROMPT="Hold a LINE, do not chase. ..."
```

## Layout

| path | what |
|---|---|
| `src/knights_archers.nim` | the game server entrypoint (`/bin/knights-archers`) |
| `src/knights_archers_player.nim` | the thin seat registrar (`/bin/knights-archers-player`) |
| `src/kaz/horde.nim` | the zombie list, the spawn schedule, the gate flow field, the march |
| `src/kaz/arrows.nim` | the in-flight arrow list |
| `src/kaz/melee.nim` | the knight's wedge |
| `src/kaz/{decide,directives,control,baselines,llm}.nim` | the per-turn decision layer |
| `src/kaz/{sim,sim_types,sim_state,server,broadcast,replays,global}.nim` | the inherited engine |
| `client/` | the broadcast chrome |
| `replay-viewer/` | the emscripten static replay bundle |
| `tools/tune_baselines.nim` | the grid harness that chose `phalanx`'s numbers |
| `docs/` | [rules](docs/RULES.md), [protocol](docs/PROTOCOL.md), [commanding](docs/COMMANDING.md) |

Forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf)
(paintbot). Rules adapted from PettingZoo's `knights_archers_zombies_v11`.

## Build and test

Everything compiles in CI (`.github/workflows/ci.yml`): the Nim suite twice
(debug and release), a raw-Docker episode from the certification fixture in the
production image, and the wasm viewer built and then **opened in a real
browser** against the replay that episode produced.

```bash
nim r --path:src tests/test_horde.nim      # any tests/*.nim, from the repo root
docker build -t coworld-knights-archers:ci .
tools/ci/docker_smoke.sh coworld-knights-archers:ci
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```
