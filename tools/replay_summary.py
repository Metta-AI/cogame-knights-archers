#!/usr/bin/env python3
"""Summarise a knights-archers `.replay` as one strict-UTF-8 JSON object on stdout.

Python 3 standard library only: no Nim, no Docker, no emsdk. This is the JSON
view of the binary `COWLDKAZ` replay the static wasm viewer parses, and it is
what phase 60's definition-of-done check reads instead of `jq .` on the raw
bytes:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                  # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason' /tmp/ep.json
    jq -r '[.directives[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json

The replay stays binary on purpose: a JSON replay would mean rewriting
replays.nim, replay_runtime.nim, static_replay_worker.js and
wasm_replay_smoke.cjs — the machinery this fork exists to reuse.

How it reads the file WITHOUT a decoder for the whole record stream:

* the header is ASCII up to the config JSON, so the config is recovered by
  BRACE-MATCHING from the first `{` (the technique the starter's AGENTS.md
  documents for prod forensics);
* the knights-archers CONTROL records — `register`, `directive`, `fallback`,
  `budget_guard`, `result` — are UTF-8 JSON objects embedded verbatim in the
  chat records, so they are recovered the same way, by scanning the remaining
  bytes for balanced `{"k":...}` objects.

Nothing here needs the record framing, so it cannot drift when the framing
changes; it only needs the two things that are text.
"""

from __future__ import annotations

import json
import sys


def brace_match(data: bytes, start: int) -> tuple[dict | None, int]:
    """Decode one balanced ``{...}`` starting at ``start``.

    Returns ``(obj, end)`` where ``end`` is the index just past the object, or
    ``(None, start + 1)`` when the bytes there are not a decodable object.
    """
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(data)):
        ch = data[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == 0x5C:      # backslash
                escaped = True
            elif ch == 0x22:      # quote
                in_string = False
            continue
        if ch == 0x22:
            in_string = True
        elif ch == 0x7B:          # {
            depth += 1
        elif ch == 0x7D:          # }
            depth -= 1
            if depth == 0:
                chunk = data[start:i + 1]
                try:
                    return json.loads(chunk.decode("utf-8")), i + 1
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None, start + 1
        elif depth == 0:
            # A stray byte before any brace: not the start of an object.
            return None, start + 1
    return None, len(data)


def summarise(path: str) -> dict:
    data = open(path, "rb").read()
    protocol = "knights-archers/v1"
    game_name = ""
    game_version = ""
    # The header is EXACT, not guessed: `magic` (8 ASCII bytes), a
    # little-endian u16 format version, then two length-prefixed strings —
    # the game name and the game version — then a u64 timestamp and the
    # length-prefixed config JSON. Scanning for a digit run instead read the
    # first ASCII digit that happened to fall inside the u64 timestamp and
    # reported gameVersion "10" for a "1" replay.
    def read_string(buf: bytes, at: int) -> tuple[str, int]:
        if at + 2 > len(buf):
            return "", at
        length = buf[at] | (buf[at + 1] << 8)
        at += 2
        if at + length > len(buf):
            return "", at
        return buf[at:at + length].decode("utf-8", "replace"), at + length

    cursor = 0
    if data[:8] == b"COWLDKAZ":
        cursor = 8 + 2                                  # magic + formatVersion
        game_name, cursor = read_string(data, cursor)
        game_version, cursor = read_string(data, cursor)
    if game_name and game_name != "knights-archers":
        protocol = game_name + "/v1"

    first = data.find(b"{")
    config: dict = {}
    if first >= 0:
        config, cursor = brace_match(data, first)
        config = config or {}

    directives: list[dict] = []
    fallbacks = 0
    registers: list[dict] = []
    budget_guards = 0
    results: dict = {}
    i = cursor
    while True:
        i = data.find(b'{"k":', i)
        if i < 0:
            break
        obj, nxt = brace_match(data, i)
        i = nxt
        if not isinstance(obj, dict):
            continue
        kind = obj.get("k")
        if kind == "directive":
            directives.append(obj)
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append(obj)
        elif kind == "budget_guard":
            budget_guards += 1
        elif kind == "result":
            results = obj.get("results", obj)

    names = [p.get("name", "") for p in (config.get("players") or [])]
    seats = int(config.get("num_agents") or config.get("numAgents") or 4)
    roles = list(config.get("roles") or [])
    if len(roles) != seats:
        half = max(1, seats // 2)
        roles = ["knight" if i < half else "archer" for i in range(seats)]
    # The in-game aliases: ROLE-identity, ranked WITHIN the role, which is the
    # only naming a seat, a prompt or a shout ever sees.
    identities = ["alpha", "beta", "gamma", "delta"]
    aliases: list[str] = []
    seen: dict[str, int] = {}
    for role in roles:
        rank = seen.get(role, 0)
        seen[role] = rank + 1
        aliases.append(f"{role.upper()}-{identities[rank % len(identities)]}")

    return {
        "protocol": protocol,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "names": names,
        "aliases": aliases,
        "roles": roles,
        "policyKinds": [r.get("kind", "") for r in registers],
        "waves": int(config.get("maxGames") or 1),
        "tickCount": len(data),
        "directives": directives,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <path.replay>", file=sys.stderr)
        return 2
    out = summarise(argv[1])
    # ensure_ascii=False keeps a non-ASCII policy label or note as real UTF-8,
    # which is exactly what the strict-parse check downstream is testing.
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
