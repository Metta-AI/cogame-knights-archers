# Training Knights & Archers

The persistent numeric bridge covers all four certified variants. It uses
each seat's exact hosted `seatViewJson`, exposes a fixed 537-feature encoding,
and passes seven action heads through the production directive parser and
controller. All four views and scripted teacher actions are frozen before a
turn's orders are applied. An episode includes every configured wave.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/knights-archers-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/knights-archers-train-bridge
```

For Metta RL, call `recipes.external.coworld_metta_rl.train`. For native
PufferLib, call `recipes.external.coworld.train`. Pass a command of the form
`[/tmp/knights-archers-train-bridge, /path/to/coworld_manifest_template.json,
default]`, choose one of the four variants, and set `players=4`. Always set a
finite timestep limit. The bridge also provides the full seat view as a
semantic observation for Observatory consumers.

# Metta post-training data

The native simulator and published `phalanx` policy export supervised
decisions for every certified variant: `default`, `horde-short`,
`horde-hard`, and `horde-tough`.

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/kaz-default 10 1 default
```

Replace the output path and final argument for another variant. Each run
plays ten complete seeded, four-seat episodes through the production
directive parser and controller. Rows contain the acting seat's hosted
prompt and parsed `phalanx` directive. Splits are by episode seed. The
manifest records source revision, variant, scores, and row counts. Existing
output directories are never overwritten.

Train with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/kaz-default \
  --output /tmp/kaz-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

The local ten-episode exports contained 1,244 train and 312 validation
examples for Default; 572 and 192 for Horde Short; 1,060 and 324 for Horde
Hard; and 472 and 76 for Horde Tough. These examples distill a scripted
teacher. They do not establish stronger league play.

One CPU optimizer step with a local tiny model and `--max-length 4096`
included every exported example in each variant. Validation loss on four
examples fell from 1.7206 to 1.7149 (Default), 1.7148 (Horde Short),
1.7148 (Horde Hard), and 1.7148 (Horde Tough). This checks the training
path; the tiny model and one update do not measure policy quality.
