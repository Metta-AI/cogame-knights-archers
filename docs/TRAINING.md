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
