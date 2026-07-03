# PokeParty — Project Context

Orientation doc for AI assistants and new contributors. Keep this current when
architecture or major features change.

## What it is

PokeParty is a SwiftUI app (macOS/iOS) for **Pokémon GO PvP**. It ingests
[PvPoke](https://pvpoke.com)'s gamemaster and ranking data, lists Pokémon by
competitive viability per league/cup, and runs a **1v1 battle simulator** so
users can test movesets and shield scenarios against the meta. It also has an
**IV rank checker** that finds a specific IV spread's rank within a league.

## Data flow

1. **Source** — `DataService` (an `actor`) fetches PvPoke JSON from
   `pvpoke.com/data/` (`gamemaster.json`, `rankings-{cp}.json`). Persistently
   cached via SwiftData with a 7-day freshness window + ETag revalidation.
   `LoadPolicy`: `.cache` (no network), `.revalidate` (ETag check), `.reload`.
2. **Store** — `RankingsStore` (`@Observable`) is the central state: loaded
   gamemaster (`pokemonById`, `movesById`, `allPokemon`), available formats, and
   ranked entries for the current format (cached per-format for instant switch).
3. **Views** read from `RankingsStore` / `RankCheckerModel`.

## Navigation (ContentView)

Three-column layout:
- **Sidebar** — `LeagueSidebar`, selection is `.format(RankingFormat)` or `.rankChecker`.
- **Content** — format → `RankingsListView` (searchable ranked list); rankChecker → `RankCheckerInputView`.
- **Detail** — format → `PokemonDetailView`; rankChecker → `RankCheckerResultsView`.

## Key types

| Type | Role |
| --- | --- |
| `RankingsStore` (@Observable) | Central state. `load(policy:)`, `move(id:) -> Move?`, `pokemon(for:) -> Pokemon?`, `simulateMatchups(for:fastMoveId:chargedMoveIds:yourShields:opponentShields:...)` (async, parallel 1v1s), `format` (setter auto-reloads), rank lookups (`rankBySpeciesId`, `name(forSpeciesId:)`). |
| `RankCheckerModel` (@Observable) | IV-checker inputs: searchText, selectedSpeciesId, levelCap, IVs (atk/def/hp clamped 0–15). |
| `DataService` (actor) | PvPoke fetch + cache. `gameMaster(policy:)`, `rankings(for:policy:)`. |
| `RankingFormat` | League/cup: title, cup ("all" = core league), cp cap, tint, etc. |
| `RankingEntry` | A Pokémon in a ranking: speciesId, rating (0–1000), score (0–100), `moveset` (3 move IDs: [fast, charged1, charged2]), `matchups`/`counters` ([Matchup]), stats. `Matchup`: opponent, rating (500 = even), isFavorable. |
| `Move` | fast vs charged distinguished by `energy == 0` (`isFast`). Fast: `energyGain`, `turns` (optional; falls back to `cooldown/500`). Charged: `energy` cost, `power`. |
| `Battle` / `MatchupSimulator` | Deterministic turn-based engine ported from PvPoke's Battle.js (energy/cooldown, shields, buffs, type effectiveness, special cases like Mimikyu Disguise). `MatchupSimulator` optimizes IVs at the CP cap, builds `BattlePokemon`, runs the battle, returns 0–1000 ratings. Matchups parallelized via TaskGroup. |

## PokemonDetailView (moveset + simulator)

Recently reworked. Notable structure:
- **Moveset section** — `MoveSelectorRow` per slot (Fast / Charged / Charged).
  Each row is an editable menu (`@State fastMoveId`, `charged1Id`, `charged2Id`,
  seeded from `entry.moveset`). Menu options flag the PvPoke `(Recommended)`
  move and show per-option numbers: fast → `N turns · DPS · EPS`,
  charged → `PWR · DPE`. Selected move gets a checkmark. Second charged slot
  offers **None** (`""`).
- Each row shows stat chips: PWR / NRG / TURNS (fast) or PWR / NRG / **COUNT** (charged).
  **COUNT** = fast moves needed to fire the charged move on each of the next 5
  throws, carrying leftover energy between throws. Renders `"Straight N"` when
  all 5 are equal, else a dashed series like `"5 - 4 - 4 - 4 - 4"`. Uses the
  *selected* fast move's `energyGain`, so it stays in sync.
- **Battle Simulator section** — shields + "Simulate vs Entire Meta" button.
  Changing any move/shield clears cached `simulated` results (via `onChange`),
  so the user re-runs. Uses menu-style (not segmented) pickers in Lists to avoid
  macOS AttributeGraph cycles — see inline comments before touching those.

## Conventions

- SwiftUI + Swift concurrency (async/await); **no Combine**. 4-space indent.
- Prefer `xcode-tools` MCP commands (XcodeRead/Write/Grep, BuildProject,
  XcodeRefreshCodeIssuesInFile) over shell.
- Testing framework for unit tests, XCUIAutomation for UI tests.
