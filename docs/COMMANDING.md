# Writing a knights-archers prompt

A player policy receives its own private decision view and returns one ordinary
squad directive. The same player image supports scripted, prompt, and Jev
policies. Model calls happen inside the player container.

```bash
coworld upload-policy coworld-knights-archers:latest \
  --name my-warden \
  --run /bin/knights-archers-player \
  --secret-env PLAYER_PROMPT="<your strategy, in plain English>"
```

`PLAYER_SCRIPTED=phalanx` or `PLAYER_SCRIPTED=stand` makes a seat play a
published baseline instead. Set `PLAYER_JEV=1` to rank tactical choices with
Jev. A seat that sets neither plays `phalanx`.

## What the model is asked

Once every 4 seconds of sim time, the game sends all four seats their private
observations from one pre-action state. A prompt player combines its own
`PLAYER_PROMPT`, the rules for its role, and that observation before calling
Claude. A Jev player independently ranks the six legal intents, visible target
and facing points, public shout, and private note. No seat sees another's
current-turn order or operator prompt.

## What it must answer

```json
{"note": "archers hold the choke, I take the north lane",
 "cogs": [{"id": "KNIGHT-alpha", "intent": "intercept", "target": [820, 300],
           "face": [900, 290], "say": "north"}]}
```

| field | cap | repair |
|---|---|---|
| `note` | ≤ 160 runes | truncated on a rune boundary; newlines collapse |
| `cogs` | exactly 1 entry — your own hero | extras dropped; empty keeps last turn's order |
| `cogs[].id` | your own alias, ≤ 16 runes | an unmatched entry is assigned by position |
| `cogs[].intent` | one of `intercept` `hold` `screen` `focus` `fall_back` `regroup` | → `intercept` |
| `cogs[].target` | `[x, y]` | clamped to the map; missing → the gate centre |
| `cogs[].face` | `[x, y]` or null | clamped; missing → the controller aims |
| `cogs[].say` | ≤ 10 runes | truncated, then printable-ASCII filtered. It is a REAL in-game shout every hero within 247 px hears. |

Parsing is tolerant: markdown fences, prose before the object, `cogs` as an
id-keyed object, a bare order with no `cogs` wrapper, numeric strings and
hyphenated intents are all accepted. Two consecutive unusable replies and the
seat plays the `phalanx` directive for that turn, with a `fallback` record in
the replay naming the cause.

## What actually wins

- **The line, not the kill count.** A cleared wave is worth 20 kills, and a wave
  that ends at 0:08 to a careless knight banks whatever it had. Your score is
  the squad's score.
- **Distance is the archer's whole role.** A zombie inside 90 px charges, and it
  covers 144 px inside one turn. An archer that walks toward its target is
  usually walking into the thing that kills it.
- **A knight is not invulnerable.** It kills once every 0.9 seconds and dies to
  one touch. Three bodies at once is a losing trade even for a mace.
- **Say what you are about to do.** All four decide simultaneously, so `say` is
  the only way two seats avoid taking the same zombie.

The two shipped champions are worked examples:

- **`knights-archers-warden`** holds a LINE and never chases. Lanes are split by
  y; knights intercept the leader in their own half; archers focus from 300–450
  px and fall back the moment anything is inside 200 px.
- **`knights-archers-volley`** kills the leader first, together: both archers
  focus the same zombie every turn (two arrows in one second is a kill; two
  arrows on two zombies is two wounded zombies), while the knights screen it.
