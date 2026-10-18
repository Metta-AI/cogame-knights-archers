## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "knights-archers-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical: "You are ONE hero defending a keep against a horde of the dead, in a top-down\narena 1235 by 659 pixels. The dead walk in at the EAST edge (x=1178) and march\nWEST toward your gate (x=40). Two knights and two archers hold the line\ntogether. You are <ROLE>.\n"
  of pvPlain: "You control ONE hero, <ROLE>, in a squad of two knights and two archers.\nTogether you defend a keep against a horde of the dead in a top-down arena\n1235 by 659 pixels. The dead enter at the EAST edge (x=1178) and march WEST\ntoward your gate (x=40).\n"
  of pvNumbered: "1. Control ONE hero: <ROLE>. Your squad has two knights and two archers.\n2. Defend the keep together against a horde of the dead.\n3. The top-down arena is 1235 by 659 pixels.\n4. The dead enter at the EAST edge (x=1178) and march WEST to your gate (x=40).\n"
  of pvQuestions: "Who do you control? ONE hero, <ROLE>, in a squad of two knights and two archers.\nWhat do you defend together? A keep against a horde of the dead.\nWhere? A top-down arena 1235 by 659 pixels.\nWhere do the dead march? From the EAST edge (x=1178) WEST toward your gate (x=40).\n"
  of pvReordered: "The dead enter at the EAST edge (x=1178) and march WEST toward the gate (x=40)\nin a top-down arena 1235 by 659 pixels. Two knights and two archers defend\nthis keep together against the horde. You control ONE of those heroes: <ROLE>.\n"
  of pvHeldoutBriefing: "Keep-defense briefing: a horde of the dead advances WEST from the EAST edge\n(x=1178) to your gate (x=40). The top-down arena measures 1235 by 659 pixels.\nYour squad consists of two knights and two archers defending together.\nYou command ONE hero, <ROLE>.\n"
  of pvHeldoutReference: "Assignment: ONE hero, <ROLE>. Squad: two knights and two archers.\nShared task: defend the keep against the horde of the dead.\nTop-down arena dimensions: 1235 by 659 pixels.\nEnemy route: EAST edge (x=1178), marching WEST toward your gate (x=40).\n"
  of pvMixed: raise newException(Defect, "unresolved mixed wording")
