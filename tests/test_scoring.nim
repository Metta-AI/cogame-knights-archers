## The scoring formula and its sign.
##
## Fully cooperative: `teamScore` is IDENTICAL for all four seats, no term is
## ever negative, and the per-seat credit epsilon is strictly smaller than one
## extra team kill — so the ordering is lexicographic, squad kills first and
## personal credit only as a tie-break.

import
  std/[json, random],
  kaz/sim,
  ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

proc scored(
  sim: var SimServer, kills: array[4, int], cleared: int
): JsonNode =
  sim.heroKills = @[kills[0], kills[1], kills[2], kills[3]]
  sim.zombiesKilled = kills[0] + kills[1] + kills[2] + kills[3]
  sim.wavesCleared = cleared
  parseJson(sim.heroResultsJson())

block theScaleIsZeroToOneAndMonotone:
  var sim = newHordeSim(maxTicks = 600, maxGames = 2)
  check(scored(sim, [0, 0, 0, 0], 0)["teamScore"].getFloat() == 0.0,
    "zero value must score 0.0")
  let full = scored(sim, [90, 90, 0, 0], 2)["teamScore"].getFloat()
  check(full == 1.0, "2 x roundTarget must score exactly 1.0, got " & $full)
  check(scored(sim, [200, 200, 200, 200], 2)["teamScore"].getFloat() == 1.0,
    "the score is CAPPED at 1.0")
  var last = -1.0
  for k in 0 .. 60:
    let value = scored(sim, [k, 0, 0, 0], 0)["teamScore"].getFloat()
    check(value >= last, "teamScore must be monotone non-decreasing in kills")
    check(value >= 0.0, "no term is ever negative")
    last = value
  for c in 0 .. 2:
    let value = scored(sim, [10, 0, 0, 0], c)["teamScore"].getFloat()
    check(value >= 0.0, "no term is ever negative")

block everySeatSharesTheTeamTermExactly:
  var
    sim = newHordeSim(maxTicks = 600, maxGames = 2)
    rng = initRand(90210)
  for trial in 0 ..< 10_000:
    let
      kills = [rng.rand(60), rng.rand(60), rng.rand(60), rng.rand(60)]
      cleared = rng.rand(2)
      results = scored(sim, kills, cleared)
      team = results["teamScore"].getFloat()
    var
      lo = 2.0
      hi = -1.0
    for value in results["scores"]:
      let score = value.getFloat()
      check(score >= team - 1e-12,
        "a seat scored BELOW the team term: " & $score & " < " & $team)
      check(score <= team + 0.004 + 1e-12,
        "a seat scored above team + epsilon: " & $score)
      lo = min(lo, score)
      hi = max(hi, score)
    check(hi - lo <= 0.004 + 1e-12,
      "the whole credit range must be <= 0.004, got " & $(hi - lo))
    ## The epsilon is strictly smaller than one extra TEAM kill, so one more
    ## kill for the squad strictly dominates the entire personal-credit range.
    check(0.004 < 1.0 / 180.0, "the epsilon must be under 1/180")
    for value in results["win"]:
      check(value.getBool() == results["win"][0].getBool(),
        "win is the same boolean for all four seats")
    check(results["win"][0].getBool() == (team >= 0.5),
      "win must equal teamScore >= 0.5")
    discard trial

block aFaultScoresWhatWasBankedAndWinsNothing:
  var sim = newHordeSim(maxTicks = 600, maxGames = 2)
  sim.endReason = ReasonFault
  sim.endRule = EndRuleSimFault
  let results = scored(sim, [70, 70, 20, 20], 2)
  check(results["teamScore"].getFloat() > 0.9,
    "a fault must score what the squad actually earned")
  for value in results["win"]:
    check(not value.getBool(), "a fault wins nothing for anybody")
  check(results["reason"].getStr() == ReasonFault, "reason must be fault")

block theDesignNotesCalibrationHolds:
  var sim = newHordeSim(maxTicks = 600, maxGames = 2)
  ## Two waves cleared at 70 kills each: (70 + 20) x 2 = 180 -> 1.000.
  check(scored(sim, [35, 35, 35, 35], 2)["teamScore"].getFloat() == 1.0,
    "140 kills + 2 clears must be 1.000")
  ## The score is a PERMILLE quantum (integer permille over 1000), so it is
  ## exactly representable and a league Elo never sees a rounding tail.
  ## One cleared at 70, one lost early at 20: 90 + 20 = 110/180 -> 0.611.
  let mixed = scored(sim, [45, 45, 0, 0], 1)["teamScore"].getFloat()
  check(abs(mixed - 0.611) < 1e-9,
    "90 kills + 1 clear must be 0.611, got " & $mixed)
  ## Two waves lost inside 40 s at 25 kills each: 50/180 -> 0.277.
  let poor = scored(sim, [25, 25, 0, 0], 0)["teamScore"].getFloat()
  check(abs(poor - 0.277) < 1e-9,
    "50 kills, nothing cleared must be 0.277, got " & $poor)
  check(poor < 0.5, "a squad that cleared nothing must not 'win'")

echo "test_scoring: ok"
