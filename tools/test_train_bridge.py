"""Exercise all certified Knights & Archers variants through the numeric protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


MANIFEST = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"


def play(binary: Path, variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(binary), str(MANIFEST), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"kaz-{variant}-{teacher}", "players": 4})
        widths = set()
        decisions = 0
        waves = set()
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [6, 1236, 660, 2, 1236, 660, 5]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            assert "seed" not in view and "your_last_directive" in view
            assert len(view["squad"]) == 3 and len(view["zombies"]) <= 64
            waves.add(view["wave"])
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 400
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {str(i) for i in range(4)}
        assert set(observation["utilities"]) == {str(i) for i in range(4)}
        assert all(-1 <= value <= 1 for value in observation["utilities"].values())
        assert len(widths) == 1 and waves == set(range(1, 1 + (1 if variant == "horde-short" else 2)))
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_simultaneous_views(binary: Path) -> None:
    next_views = []
    next_teachers = []
    for intent in ("hold", "focus"):
        process = subprocess.Popen(
            [str(binary), str(MANIFEST), "default"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        request({"kind": "reset", "seed": "kaz-simultaneous", "players": 4})
        action = {"intent": intent, "target_x": 600, "target_y": 300,
                  "face": 0, "face_x": 0, "face_y": 0, "say": ""}
        next_views.append(request(
            {"kind": "step", "decision_id": 0, "response": json.dumps(action)}
        )["observation"]["semantic_view"])
        next_teachers.append(request({"kind": "teacher"})["response"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert next_views[0] == next_views[1]
    assert next_teachers[0] == next_teachers[1]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_simultaneous_views(binary)
    for variant in ("default", "horde-short", "horde-hard", "horde-tough"):
        for teacher in (True, False):
            play(binary, variant, teacher)
