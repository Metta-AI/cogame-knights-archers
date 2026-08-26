## Release-only: a full-length episode has to fit inside a CI runner.
##
## `NIM_TESTS_RELEASE_ONLY` lists this file, so it never runs in the debug pass
## (debug builds are 10-50x slower through the per-pixel map code and would
## measure the compiler, not the game).

import
  std/[strutils, times],
  kaz/baselines,
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

let began = epochTime()
var world = newHordeSim(maxTicks = 2304, maxGames = 2)
world.gameEventLoggingEnabled = false
let run = world.runScripted(blPhalanx)
let elapsed = epochTime() - began

echo "test_perf: ", run.ticks, " ticks, ", run.teamKills, " kills, ",
  world.zombiesSpawned, " spawned, in ", elapsed.formatFloat(ffDecimal, 2), " s"

check(run.waves == 2, "both waves must play, played " & $run.waves)
check(run.ticks > 2000, "the episode must be full length, got " & $run.ticks)
## The design's bound: 2 x 2304 ticks of sim plus mask compilation, forty
## marching zombies and live arrows, in well under two minutes on a runner.
check(elapsed < 120.0,
  "a full episode took " & elapsed.formatFloat(ffDecimal, 2) &
    " s, over the 120 s bound")

echo "test_perf: ok"
