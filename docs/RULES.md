# Knights Archers Zombies — rules

Four heroes hold one gate against a rising horde, and a single mistake ends the
wave for everybody.

## The board

A fixed **1235 × 659** arena (`mapPath: "arena"`), 24 ticks per second. The dead
walk in at the **breach** on the east edge (`x = 1178`) and march west toward the
**gate** on the west edge (`x = 40`). Both are baked into the floor art, so the
geometry of the game is legible with the HUD off.

## The seats

`num_agents` is **4**. One seat drives exactly one hero.

| Seat | Alias — the only name the game uses | Role | Weapon |
|---|---|---|---|
| 0 | `KNIGHT-alpha` | knight | mace |
| 1 | `KNIGHT-beta` | knight | mace |
| 2 | `ARCHER-alpha` | archer | bow |
| 3 | `ARCHER-beta` | archer | bow |

| | Knight | Archer |
|---|---|---|
| speed | 66 px/s | 56 px/s (85 %) |
| reach | 52 px, ±45° wedge, line of sight required | 528 px, straight |
| damage | 2 — one blow kills | 1 — two arrows kill |
| cooldown | 0.75 s | 0.5 s |

There is **no friendly fire**: arrows pass through heroes.

## The horde

Zombies enter on a ramping schedule — 0.29/s at the start of a wave rising to
1.20/s after 80 s, about **79 zombies** over a full wave, never more than 40
alive at once. Each has **2 hit points** and walks at **36 px/s** down a flow
field toward the gate. A zombie with a living hero inside **90 px** stops
marching and charges it. Zombies do not collide with each other.

## Losing

The wave ends **the instant**:

1. a zombie's centre reaches `x <= 40` — a **breach**; or
2. a zombie's centre comes within **26 px** of any living hero — a **casualty**.

There are no respawns, no second chances, and no hit-point pool: `hitPoints` 1,
`lives` 1. A hero who is not you dying ends your wave too.

## Winning

An episode is **two waves** of 2304 ticks (96 s). Surviving a whole wave
**clears** it.

```
kills      = every zombie the four of you killed, over the episode
cleared    = waves that ran their full 96 s with the line intact (0, 1 or 2)
teamValue  = kills + 20 * cleared
teamScore  = min(teamValue, 180) / 180                 -- the same for ALL FOUR
credit[s]  = 0.004 * kills[s] / max(1, kills)          -- the tie-break only
scores[s]  = teamScore + credit[s]
win[s]     = teamScore >= 0.5
```

Everybody's score is the same score. The personal credit range (0.004) is
**smaller than one extra team kill** (1/180 = 0.005556), so killing more than
your share is worth nothing if the line breaks.

## The published scripted baselines

Both emit the same directive object an LLM does, on the same 4.0 s cadence.
They are published so that "cooperating with a partner you did not write" here
means "a partner whose rules you know".

- **`phalanx`** — the certification player, the per-turn fallback, the driver of
  a seat that never connects, and the default. It ranks the live zombies by gate
  distance and divides them so two seats never duplicate work: KNIGHT-alpha
  intercepts the leader, KNIGHT-beta the second, ARCHER-alpha focuses the leader
  and ARCHER-beta the third. An archer with anything inside 150 px falls back
  toward the gate for a turn; a knight with four bodies inside 90 px gives 140 px
  of ground for a turn. With no zombies alive everybody holds the choke —
  knights at `[560, 240]` and `[560, 420]`, archers at `[300, 240]` and
  `[300, 420]`.
- **`stand`** — deliberately weaker and different in shape: every hero holds its
  choke post for the whole wave and never moves. It kills whatever walks into
  reach and leaks everything that walks around it.

`tools/tune_baselines.nim` is the grid harness that chose `phalanx`'s three
numbers; `tools/tune_baselines --check` re-plays them in CI.

## Orders

Every 4 seconds each seat issues ONE order for its own hero and a deterministic
controller executes it for the next 4 seconds. See
[COMMANDING.md](COMMANDING.md) for the schema and
[PROTOCOL.md](PROTOCOL.md) for the wire.

| intent | what the controller does |
|---|---|
| `intercept` | meet the zombie closest to the gate and kill it |
| `hold` | stand at `target` and kill whatever walks into reach |
| `screen` | stand 120 px in front of the leader, between it and the gate |
| `focus` | attack the zombie nearest `target` |
| `fall_back` | walk to `target` and do not attack |
| `regroup` | move to the middle of your surviving squadmates |
