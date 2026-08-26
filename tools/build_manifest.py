import json, io, os
os.chdir('/tmp/kaz')

def text(path):
    return open(path, encoding='utf-8').read()

CONST = dict(
    seed=679961, maxTicks=2304, maxGames=2, turnTicks=96,
    turnBudgetMs=7000, attempt1Ms=4500, retryMs=2000, turnSpacingMs=9000,
    wallClockBudgetSeconds=690, lobbyJoinTimeoutTicks=2400,
    startWaitTicks=120, gameOverTicks=72,
    zombieHp=2, zombieSpeed=384, zombieReach=26, zombieLungePx=90,
    zombieStuckTicks=24, zombieSpawnX=1178, gateX=40,
    spawnStartPerMille=12, spawnMaxPerMille=50, spawnSaturateTicks=1920,
    spawnCapAlive=40,
    knightReach=52, knightArcBrads=32, knightDamage=2, knightCooldown=18,
    swingTicks=4, archerSpeedPct=85,
    arrowSpeed=3072, arrowRange=528, arrowLifeTicks=44, arrowDamage=1,
    arrowCooldown=12, arrowHitRadius=14,
    archerRange=460, roleStandoff=300, screenStandoff=120, archerPanicPx=150,
    closeCallPx=200, clearBonus=20, roundTarget=90, creditEpsilonPerMille=4,
    maxOutputTokens=900,
)

SEAT_NAMES = ["Knight A", "Knight B", "Archer A", "Archer B"]
SLOTS = [{"team": "red"} for _ in range(4)]
ROLES = ["knight", "knight", "archer", "archer"]

# `tokens` is declared in config_schema but never set in a variant or the cert
# fixture: the runner injects the join tokens, and `coworld certify` rejects a
# game_config that carries them ("game_config must not include runner-managed
# tokens").
def variant_config(**over):
    c = {
        "players": [{"name": n} for n in SEAT_NAMES],
        "slots": list(SLOTS),
        "roles": list(ROLES),
        "num_agents": 4,
        "minPlayers": 4,
        "lives": 1,
        "hitPoints": 1,
        "mapPath": "arena",
        "fogOfWar": False,
        "fastMode": True,
        "showPlayerLabels": False,
    }
    c.update(CONST)
    c.pop("maxOutputTokens", None)
    c.update(over)
    return c

def intprop(default, lo=None, hi=None, desc=""):
    p = {"type": "integer", "default": default}
    if lo is not None: p["minimum"] = lo
    if hi is not None: p["maximum"] = hi
    if desc: p["description"] = desc
    return p

config_props = {
    "tokens": {"type": "array", "items": {"type": "string"},
               "minItems": 4, "maxItems": 4,
               "description": "One join token per seat."},
    "players": {"type": "array", "minItems": 4, "maxItems": 4,
                "items": {"type": "object",
                          "properties": {"name": {"type": "string"}},
                          "additionalProperties": True},
                "description": "One entry per seat, spectator-side names."},
    "slots": {"type": "array", "minItems": 4, "maxItems": 4,
              "items": {"type": "object",
                        "properties": {"team": {"type": "string"}},
                        "additionalProperties": True},
              "description": "Every hero is on the red side; there is no second team."},
    "roles": {"type": "array", "minItems": 4, "maxItems": 4,
              "items": {"type": "string", "enum": ["knight", "archer"]},
              "description": "Per seat: knight (melee) or archer (ranged)."},
    "seed": intprop(679961, desc="Episode seed; every zombie spawn derives from it."),
    "num_agents": {"type": "integer", "minimum": 4, "maximum": 4, "default": 4,
                   "description": "Seats. Two knights and two archers, always four."},
    "minPlayers": intprop(4, 4, 4),
    "lives": intprop(1, 1, 1, "One death ends the wave; there are no respawns."),
    "hitPoints": intprop(1, 1, 1, "A touch kills; there is no hit-point pool."),
    "maxTicks": intprop(2304, 240, 7200, "Ticks in one wave (2304 = 96 s at 24 Hz)."),
    "maxGames": intprop(2, 1, 4, "Waves per episode."),
    "turnTicks": intprop(96, 1, 2304, "Sim ticks per decision turn."),
    "turnBudgetMs": intprop(7000, 1000, 60000),
    "attempt1Ms": intprop(4500, 1000, 60000),
    "retryMs": intprop(2000, 1000, 60000),
    "turnSpacingMs": intprop(9000, 0, 60000,
        "Wall-clock floor between batch STARTS; holds four seats under the "
        "Bedrock sidecar's 30 req/min per-episode cap."),
    "wallClockBudgetSeconds": intprop(690, 1, 720,
        "Engine hard stop. 60% of the assumed 1200 s episodeTimeoutSeconds is "
        "720; every shipped variant is at or under 690."),
    "lobbyJoinTimeoutTicks": intprop(2400, 0, 7200),
    "startWaitTicks": intprop(120, 0, 2400),
    "gameOverTicks": intprop(72, 1, 720),
    "mapPath": {"type": "string", "enum": ["arena"], "default": "arena"},
    "fogOfWar": {"type": "boolean", "default": False,
                 "description": "False: every seat sees the whole board."},
    "fastMode": {"type": "boolean", "default": True},
    "showPlayerLabels": {"type": "boolean", "default": False},
    "zombieHp": intprop(2, 1, 8, "A mace does 2, an arrow 1."),
    "zombieSpeed": intprop(384, 1, 2048, "Motion units/tick; 384 = 36 px/s."),
    "zombieReach": intprop(26, 1, 200, "Px: this close to a hero centre kills it."),
    "zombieLungePx": intprop(90, 0, 600),
    "zombieStuckTicks": intprop(24, 1, 240),
    "zombieSpawnX": intprop(1178, 0, 1234, "The breach column."),
    "gateX": intprop(40, 1, 600, "The gate line; a zombie at or past it wins."),
    "spawnStartPerMille": intprop(12, 0, 1000),
    "spawnMaxPerMille": intprop(50, 0, 1000),
    "spawnSaturateTicks": intprop(1920, 1, 7200),
    "spawnCapAlive": intprop(40, 1, 64),
    "knightReach": intprop(52, 1, 400),
    "knightArcBrads": intprop(32, 1, 63, "Wedge half-angle; 32 brads = 45 deg."),
    "knightDamage": intprop(2, 1, 8),
    "knightCooldown": intprop(18, 1, 240),
    "swingTicks": intprop(4, 1, 48),
    "archerSpeedPct": intprop(85, 1, 200),
    "arrowSpeed": intprop(3072, 1, 8192, "Motion units/tick; 3072 = 288 px/s."),
    "arrowRange": intprop(528, 1, 2000),
    "arrowLifeTicks": intprop(44, 1, 480),
    "arrowDamage": intprop(1, 1, 8),
    "arrowCooldown": intprop(12, 1, 240),
    "arrowHitRadius": intprop(14, 1, 200),
    "archerRange": intprop(460, 1, 2000),
    "roleStandoff": intprop(300, 0, 2000),
    "screenStandoff": intprop(120, 0, 2000),
    "archerPanicPx": intprop(150, 0, 2000),
    "closeCallPx": intprop(200, 0, 2000),
    "clearBonus": intprop(20, 0, 1000, "Team value banked for a cleared wave."),
    "roundTarget": intprop(90, 1, 1000, "Team value worth 1.0 for one wave."),
    "creditEpsilonPerMille": intprop(4, 0, 999,
        "The whole per-seat kill-credit range, in permille. 4 is deliberately "
        "smaller than one extra team kill (1/180 = 5.6 permille)."),
    "model": {"type": "string", "default": "",
              "description": "Pinned Bedrock/Anthropic model; empty = auto."},
    "maxOutputTokens": intprop(900, 1, 8192),
}

seat_arr = lambda t, d: {"type": "array", "items": {"type": t}, "minItems": 4,
                         "maxItems": 4, "description": d}
wave_arr = lambda t, d: {"type": "array", "items": {"type": t}, "minItems": 1,
                         "maxItems": 4, "description": d}

results_props = {
    "names": seat_arr("string", "Real policy names, spectator side."),
    "scores": seat_arr("number", "teamScore + the kill-credit epsilon."),
    "win": seat_arr("boolean", "The same boolean for all four seats."),
    "role": seat_arr("string", "knight or archer."),
    "alias": seat_arr("string", "The in-game anonymous alias."),
    "kills": seat_arr("integer", "Zombies whose last damage came from this seat."),
    "hits": seat_arr("integer", "Damaging connections."),
    "shots": seat_arr("integer", "Arrows loosed or swings thrown."),
    "llmTurns": seat_arr("integer", "Turns whose directive came from an LLM."),
    "fallbackTurns": seat_arr("integer", "Turns that fell back to scripted."),
    "teamScore": {"type": "number", "minimum": 0, "maximum": 1,
                  "description": "min(kills + 20*cleared, 180)/180."},
    "teamKills": {"type": "integer", "minimum": 0},
    "wavesCleared": {"type": "integer", "minimum": 0},
    "waveTicks": wave_arr("integer", "Ticks each wave played."),
    "waveEndRules": wave_arr("string", "How each wave ended."),
    "waveKills": wave_arr("integer", "Kills banked in each wave."),
    "closestCallPx": wave_arr("integer", "Closest a zombie came to the gate."),
    "reason": {"type": "string", "enum": ["complete", "deadline", "fault"]},
    "endRule": {"type": "string",
                "enum": ["full_time", "breach", "casualty", "wall_clock",
                         "sim_fault", "host_error"]},
    "games": {"type": "integer", "minimum": 0},
    "finalTick": {"type": "integer", "minimum": 0},
    "seed": {"type": "integer"},
}

variants = []
for vid, name, desc, over in [
    ("default", "Horde — two waves",
     "The league variant: two 96-second waves against the shipped horde. One "
     "breach or one hero death ends the wave.", {}),
    ("horde-short", "Horde — one wave",
     "A single 96-second wave. Half the episode, same rules — the quick look.",
     {"maxGames": 1}),
    ("horde-hard", "Horde — dense",
     "The spawn rate saturates at 72 per mille instead of 50: about half again "
     "as many dead over a wave, same seat count.",
     {"spawnMaxPerMille": 72}),
    ("horde-tough", "Horde — armoured dead",
     "Three hit points per zombie: a mace no longer kills in one blow and an "
     "archer needs three arrows. Same seat count, same clock.",
     {"zombieHp": 3}),
]:
    variants.append({"id": vid, "name": name, "description": desc,
                     "game_config": variant_config(**over)})

cert_config = {
    "players": [{"name": n} for n in SEAT_NAMES],
    "slots": list(SLOTS),
    "roles": list(ROLES),
    "num_agents": 4,
    "minPlayers": 4,
    "lives": 1,
    "hitPoints": 1,
    "seed": 679961,
    "mapPath": "arena",
    "fogOfWar": False,
    "maxTicks": 600,
    "maxGames": 2,
    "turnTicks": 96,
    "turnBudgetMs": 7000,
    "attempt1Ms": 4500,
    "retryMs": 2000,
    "turnSpacingMs": 0,
    "wallClockBudgetSeconds": 180,
    "lobbyJoinTimeoutTicks": 1440,
    "startWaitTicks": 0,
    "gameOverTicks": 24,
    "spawnStartPerMille": 40,
    "spawnSaturateTicks": 480,
    "fastMode": True,
    "showPlayerLabels": False,
}

manifest = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/metta/main/packages/coworld/src/coworld/coworld_manifest_schema.json",
    "tags": ["horde", "cooperative", "knights-archers", "melee", "ranged",
             "llm", "pettingzoo"],
    "episode_timeout_minutes": 20,
    "game": {
        "name": "knights-archers",
        "owner": "daveey",
        "description": (
            "Four-seat cooperative horde defence. Two knights and two archers "
            "hold one gate against a marching horde of the dead; one breach, "
            "or one hero death, ends the wave for everybody. A policy is a "
            "prompt."),
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "runnable": {
            "type": "game",
            "image": "{{KNIGHTS_ARCHERS_IMAGE}}",
            "run": ["/bin/knights-archers"],
            "env": {
                "ANTHROPIC_API_KEY_URI":
                    "secret://coworld/knights-archers/anthropic_api_key"
            },
            "source_url":
                "https://github.com/Metta-AI/cogame-knights-archers/tree/main",
        },
        "config_schema": {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": False,
            "required": ["tokens", "players"],
            "properties": config_props,
        },
        "results_schema": {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": False,
            "required": ["names", "scores", "win", "role", "reason", "endRule"],
            "properties": results_props,
        },
        "protocols": {
            "player": {"type": "text", "value": text("docs/PROTOCOL.md")},
            "global": {"type": "text", "value": text("docs/PROTOCOL.md")},
        },
        "docs": {
            "readme": {"type": "text", "value": text("README.md")},
            "pages": [
                {"id": "rules", "title": "Rules",
                 "content": {"type": "text", "value": text("docs/RULES.md")}},
                {"id": "protocol", "title": "Wire protocol",
                 "content": {"type": "text", "value": text("docs/PROTOCOL.md")}},
                {"id": "commanding", "title": "Writing a knights-archers prompt",
                 "content": {"type": "text", "value": text("docs/COMMANDING.md")}},
            ],
        },
    },
    "player": [{
        "id": "baseline",
        "type": "player",
        "name": "Phalanx Baseline",
        "description": (
            "Scripted hero: knights intercept the two leading zombies, archers "
            "focus-fire and back off when anything gets close."),
        "image": "{{KNIGHTS_ARCHERS_IMAGE}}",
        "run": ["/bin/knights-archers-player"],
        "env": {"PLAYER_SCRIPTED": "phalanx"},
        "source_url":
            "https://github.com/Metta-AI/cogame-knights-archers/tree/main",
        "resources": {
            "requests": {"cpu": "100m", "memory": "64Mi"},
            "limits": {"cpu": "1"},
        },
    }],
    "variants": variants,
    "certification": {
        "players": [{"player_id": "baseline"} for _ in range(4)],
        "game_config": cert_config,
    },
}

with io.open("coworld_manifest_template.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("wrote", os.path.getsize("coworld_manifest_template.json"), "bytes")
