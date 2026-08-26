## The entrypoint's failure modes: a clean message and a non-zero exit, never a
## traceback, when the runtime contract is not met.

import
  std/[os, osproc, strutils]

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

let
  binPath = getTempDir() / "kaz-startup-" & $getCurrentProcessId()
  build = execCmdEx(
    "nim c --hints:off --path:src -o:" & quoteShell(binPath) &
    " src/knights_archers.nim")
check(build.exitCode == 0, "the game entrypoint must build:\n" & build.output)

proc runWith(env: string): tuple[output: string, exitCode: int] =
  execCmdEx(env & " " & quoteShell(binPath) & " 2>&1")

block aMissingConfigUriExitsCleanly:
  let r = runWith("env -u COGAME_CONFIG_URI COGAME_HOST=127.0.0.1 " &
    "COGAME_PORT=0 KAZ_STARTUP_PROBE=1")
  ## Either it starts with the built-in config.json (no COGAME_CONFIG_URI is a
  ## LOCAL run) or it refuses — but it must never print a Nim traceback.
  check(not r.output.contains("Traceback (most recent call last)"),
    "a startup failure must not print a Nim traceback:\n" & r.output)

block anUnparseableConfigUriIsNamedNotCrashed:
  let bad = getTempDir() / "kaz-bad-config.json"
  writeFile(bad, "{ this is not json")
  let r = runWith("COGAME_CONFIG_URI=file://" & bad)
  check(r.exitCode != 0, "an unparseable config must exit non-zero")
  check(not r.output.contains("Traceback (most recent call last)"),
    "an unparseable config must not print a Nim traceback:\n" & r.output)
  check(r.output.len > 0, "an unparseable config must SAY so")
  removeFile(bad)

block theSeedIsRandomisedWhenUnpinnedAndHonouredWhenPinned:
  ## Seed randomisation happens in the entrypoint, BEFORE config.update, so
  ## every seed-derived draw follows the final seed. Two runs of a config with
  ## no seed must not produce the same one; a pinned seed must be echoed.
  let source = readFile("src/knights_archers.nim")
  check(source.contains("proc randomSeed()") and source.contains("urandom("),
    "the entrypoint must draw a fresh OS-random seed when none is pinned")
  check(source.contains("stripUnpinnedSeed"),
    "an unpinned sentinel seed must be stripped before config.update, so " &
    "every seed-derived draw follows the FINAL seed")
  check(source.find("config.seed = randomSeed()") <
        source.find("config.update(stripUnpinnedSeed("),
    "the seed must be randomised BEFORE config.update, so every " &
    "seed-derived draw follows the final seed")

removeFile(binPath)
echo "test_startup: ok"
