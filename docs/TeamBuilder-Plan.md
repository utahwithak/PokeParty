# 3v3 Team Building & Simulation — Implementation Plan

> **Status:** Living document. Multiple agents may work from this. Check the
> **Milestone checklist** at the bottom and claim a task by marking it
> `[~] (in progress — <agent/initials>)` before starting, `[x]` when done.
>
> Last updated: 2026-07-10

---

## 0. TL;DR / Mental model

There are **two fundamentally different kinds of "3v3"** here, and conflating them
is the #1 way this goes wrong:

| Concept | What it is | Engine needed | Cost |
|---|---|---|---|
| **Team Analysis (the "Team Builder")** | Grade one team of 3 by running each meta mon **1v1** against your 3 members and aggregating a threat matrix. Produces the A–F grades (Coverage/Bulk/Safety/Consistency), the Threats list, and Suggested Teammates. | **Existing `Battle` 1v1 engine** — no switching. | Cheap. ~(meta size × 3) 1v1 sims per team. |
| **True 3v3 Battle** | Two full teams fight with lead selection, **switching**, shield/energy carryover, farming down, CMP, switch-timer. Produces one win/loss + margin. | **New engine layer above `Battle`** (does not exist yet). | Expensive. Combinatorial over leads/switch decisions. |

- **PvPoke's website "Team Builder" is the first kind** (matrix of 1v1s). That is
  what the user means by *"simple team builder with A–F rankings on coverage,
  consistency, etc, with the same data as the website."* It reuses what we already have.
- **The Advanced Team Finder and Best Teams** need the second kind (real 3v3
  battles between teams), which is the massive/parallelizable part.

**Build order:** Team Analysis first (reuses engine, immediate visible value) →
True 3v3 engine second → Finder/Best-Teams on top of it.

---

## 1. What exists today (as of this plan)

### Battle engine (`PokeParty/Engine/`) — faithful PvPoke 1v1 port, deterministic
- `Battle` (`final class`): `init(_ a: BattlePokemon, _ b: BattlePokemon)`, `simulate()`,
  `battleRating(forIndex:) -> Int` (0–1000, 500 = tie). Models shields, energy,
  cooldowns, CMP, buffs, Disguise. **No switching.** Single-threaded/synchronous.
- `MatchupSimulator` (`enum`, static bridge from app models → engine):
  - `struct Combatant { let species: Pokemon; let shadow: Bool; let fastMoveId: String; let chargedMoveIds: [String] }`
  - `optimalStats(for:cpCap:levelCap:) -> BattlePokemon.Stats?` — **expensive** IV optimization, cache it.
  - `makeBattlePokemon(_:stats:movesById:shields:startEnergy:) -> BattlePokemon?` — cheap.
  - `rate(_:statsA:_:statsB:movesById:shieldsA:shieldsB:) -> (a: Int, b: Int)?` — run 1v1, return both ratings.
  - convenience `rate(_:_:cpCap:movesById:shieldsA:shieldsB:levelCap:)`.
- `BattlePokemon` (`final class`): mutable battle state. Has `startEnergy`,
  `startingShields`, `startStatBuffs`, `baitShields`, `optimizeMoveTiming`, `farmEnergy`,
  `applyStatBuffs`, `reset()`. **These knobs are exactly what a 3v3 engine needs**
  (carry energy/HP/shields/buffs across a switch).
- `DamageCalculator`, `TypeChart`, `ActionLogic` (deterministic AI incl. shield
  decisions via `wouldShield`), `TimelineAction`.

### Data models (`PokeParty/Models/`)
- `Pokemon`: `dex`, `speciesName`, `speciesId`, `baseStats(atk/def/hp)`, `types:[String]`,
  `fastMoves:[String]`, `chargedMoves:[String]`, `tags`, `released`, `family`, `formChange`.
  Computed: `displayTypes`, `isShadow`, `hasDisguise`.
- `Move`: `moveId`, `name`, `type`, `power`, `energy`, `energyGain`, `cooldown`, `turns`,
  `buffs`, `buffTarget`, `buffApplyChance`. `isFast` = `energy == 0`.
- `League` (great/ultra/master), `RankingFormat` (cup+cp, `isCoreLeague`, `hasRankings`).
- `RankingEntry`: `speciesId`, `speciesName`, `rating`, `score:Double?`, `moveset:[String]`,
  `matchups:[Matchup]`, `counters:[Matchup]`, `moves:Moves?`, `stats:Stats?`.
  `Matchup { opponent, rating(Int), isFavorable }`.

### Services / Stores
- `DataService` (actor, singleton): `gameMaster(policy:)`, `rankings(for:policy:)`,
  fetches from `https://pvpoke.com/data/` with ETag/SwiftData cache (`ResourceCache`).
  Rankings URL: `rankings/{cup}/overall/rankings-{cp}.json`.
- `RankingsStore` (`@MainActor @Observable`): the hub. Holds `pokemonById`, `movesById`,
  `entries`, `rankBySpeciesId`, `allPokemon`, `cupFormats`, per-format `rankingsCache`.
  Methods: `load`, `refresh`, `entry(id:)`, `pokemon(for:)`, `move(id:)`, `family(for:)`,
  `simulateMatchups(...)` (already drives live 1v1 matchup calc in the UI).
- `IVCalculator`: CPM table, `optimalStats(...)`, `rankedCombos(...)`, `rank(...)`.

### UI (`PokeParty/Views/`, `ContentView.swift`)
- `NavigationSplitView` (3 columns). Sidebar selection enum in `LeagueSidebar.swift`:
  `enum SidebarSelection { case format(RankingFormat); case rankChecker }`.
- Content/detail switch on selection in `ContentView`. Stores injected: `RankingsStore`,
  `RankCheckerModel`.
- Reusable components: `TypeBadge`/`TypeBadgeRow`/`ShadowBadge`, `ScoreBadge`,
  `StatBar`, `RatingBar`, `RankingRow`, `MoveStat`, `MoveSelectorRow`, `AttributionFooter`.

---

## 2. The PvPoke Team Builder algorithm (exact — for Milestone 1)

Ported from `pvpoke/pvpoke` (`TeamInterface.js`, `TeamRanker.js`, `Pokemon.js`,
`Battle.js`, `RankerOverall.js`, `base.json`). **Reproduce these constants exactly.**

### 2.1 Battle rating (already implemented — matches `battleRating(forIndex:)`)
`floor((hpFrac_self + dmgFrac_dealt) * 500)`. 0–1000, 500 = tie.
Rating color classes: tie `==500`; close-loss `250<r<500`; loss `<=250`;
close-win `500<r<750`; win `>=750`.

### 2.2 Shields
Team builder default = **single scenario, 1 shield each**. Optional "average" mode
runs `[0,0]` and `[1,1]` and combines with a 1:3-weighted geometric mean:
`round( (r0 * r1^3) ^ (1/4) )`.

### 2.3 Threats
For each candidate in the meta pool (see §2.7), simulate it **as attacker** vs each of
your 3 team members (1 shield each by default). Candidate battle rating per matchup → `r`.
Soften into a ranking **score**:
```
if r > 500:  score = 500 + (r - 500)^0.75      // compress wins
else:        score = r / 2                       // halve losses
```
Meta-relevance weighting (`isMetaFactor = 0.85`), when candidate is in the format's
`meta-group` curated list:
```
if score > 500 && metaRelevant:  score += (1000 - score) * 0.85
else if score > 500:             score -= (score - 500) * 0.15
```
Candidate's overall `matchupScore` = mean of its 3 per-matchup scores. Sort threats
descending by `matchupScore`. Table shows top N with raw per-cell ratings colored.

### 2.4 avgThreatScore (feeds Coverage grade)
Walk sorted threats, build `counterTeam` of the **6 most distinct** top threats
(skip shadows unless allowed, `_xs`, `teambuilderexclude`, excluded, and near-dupes via
a similarity check). `avgThreatScore = round( sum(top6 raw ratings) / 6 )`. Higher = worse.

### 2.5 The four grades — `letterGrade(value, goal)`
```
p = value / goal;  A: p>=.9  B: p>=.8  C: p>=.7  D: p>=.6  else F   (no +/-)
```
- **Coverage:** `letterGrade(1200 - avgThreatScore, 680)`.
- **Bulk:** team mean of `effectiveDef * hp` (`effectiveDef = stats.def × buffMult × shadowDefMult`, buffs 0 here).
  Goal by league: `{1500: 22000, 2500: 35000 (Premier cup: 33000), 10000: 35000, 500: 10000}`.
- **Safety:** team mean of each mon's **switches** category score `scores[2]` (default 60 if
  absent) / **98**. ⚠️ *Data dependency* — see §2.8.
- **Consistency:** team mean of `Pokemon.calculateConsistency()` (0–100) / **98**. See §2.6.

There is **no single aggregate team grade**; the four are shown independently. The one
team-level scalar is `threat-score` = `avgThreatScore`.

### 2.6 `calculateConsistency()` (port from `Pokemon.js`)
Measures how bait-dependent a moveset is (0–100). Only meaningful with 2 charged moves
(else returns 100). Per effectiveness scenario (`[1,1]`, plus `[0.625,1]` & `[1,0.625]`
if the two charged moves differ in type): compute each charged move's DPE, sort, compute a
`factor` for how much damage comes from the cheaper/spammable move vs needing the expensive
one (weighted by cycle fast-move damage). Special cases: `POWER_UP_PUNCH` DPE×2;
self-debuffing / `ACID_SPRAY` tie-breaks; cheap-move-energy-near-expensive bonus
`factor += (1-factor)*((cheapE-30)/(expE-30))*0.5` (self-buffing baits use `-20`, no `0.5`).
`buffChanceFactor` penalizes probabilistic buffs (chance in (.15,1)):
`buffConsistency = 0.5 + |0.5 - chance|`; `buffsAsDamage = dmg + stages*25*(1-buffConsistency)`;
factor += `dmg/buffsAsDamage` else +1; then `/moveCount`.
`consistencyScore *= factor * buffChanceFactor` per scenario; geometric-mean across
scenarios (`^(1/numScenarios)`). Flat penalties: `POWER_UP_PUNCH ×.85`, `LUNGE ×.85`,
`FEATHER_DANCE ×.75`, `BUBBLE_BEAM ×.75`. Final = `round(score*1000)/10`.

### 2.7 Meta / opponent pool — `generateFilteredPokemonList`
Released, non-banned, meeting the league min stat-product `hp·atk·def/1000`:
`{1500: 1370, 2500: 2800, 500: 0, else(10000): 4900}`. GL (<2500) drops
`greatLeagueIneligible`; tag include-overrides; then cup `include`/`exclude`.

### 2.8 Suggested teammates ("Recommended")
`altRankings = rank(counterTeam /*the 6 threats*/, ..., "team-alternatives")` — i.e. rank
the whole eligible pool **as attackers against your top-6 threats** ("what beats the things
that beat you"), excluding your current members. Same score transform + 0.85 meta weighting
as §2.3, averaged over the ≤6 threats. Sort descending → recommended teammates.

### 2.9 Data dependency for **Safety** grade
`scores[2]` = the "switches" category score, from PvPoke's *precomputed per-category
ranking JSON* (not the overall file we currently fetch). Two options:
- **(A) Fetch it:** also download `rankings/{cup}/switches/rankings-{cp}.json` (same shape,
  has `scores`/`score`). Extend `DataService`/`RankingEntry`. Cheapest to match the site.
- **(B) Recompute:** run the "switches" RankerScenario (`shields [1,1]`, `energy [4,0]`) over
  the meta ourselves. Needed anyway for a fully-offline finder. Bigger lift.
Recommendation: **(A)** for Milestone 1; keep (B) in mind for the finder.

### 2.10 RankerScenarios (for later — true category ranking / finder)
From `base.json`: `leads [1,1] e[0,0]`, `closers [0,0] e[0,0]`,
`switches [1,1] e[4,0]`, `chargers [1,1] e[6,0]`, `attackers [0,1] e[0,0]`.
`energy` = turns of fast-move advantage preloaded (`energy*500/fastCooldown` fast moves).
`settings: partySize 3, maxBuffStages 4, buffDivisor 4`.

### 2.11 What we still borrow from PvPoke's precomputed output (→ Milestone 6)
Everything the Team Builder *shows* is computed by us EXCEPT four things that we
currently read from PvPoke's downloaded `rankings-{cp}.json`. All four are derivable
from the gamemaster + our own battle engine — that's exactly what PvPoke's server-side
`Ranker` does. What we borrow, and how to self-produce it:

| Borrowed value | Used for | How to compute it ourselves |
|---|---|---|
| **The meta pool** (which mons) + ordering | threat/teammate candidates, meta-relevance | `MetaPool`: port `generateFilteredPokemonList` — min stat-product filter over gamemaster (§2.7). *Small.* |
| **`scores[2]` switches score** | Safety grade | Run the **switches** RankerScenario (shields [1,1], energy [4,0]) over the meta and normalize to 0–100 (§2.10). Falls out of the local Ranker. *Medium.* |
| **Recommended moveset** per mon | meta candidates + default team movesets | Port PvPoke's moveset auto-selection (weighting/search over move combos). *Hardest.* |
| **Meta-relevance** (the 0.85 group) | threat/teammate weighting | The curated `meta-group`; approximated now as top-40 of rankings. Comes from the local Ranker's overall order. |

Not borrowed but always needed from *somewhere*: `gamemaster.json` (base stats, moves,
type chart) — raw game data, not a computed seed. Bundle a snapshot or keep fetching it.

**Stats** (`atk/def/hp`) are NOT a real dependency — `IVCalculator` already computes them
(it's the fallback); we read the ranking copy only for speed.

The local Ranker's core is the **N×N 1v1 matrix across the 5 scenarios**, iterated a few
passes with opponent-relevance weighting, normalized to 0–100 per category. It is
expensive (~N²×5 battles, GL N≈600 ⇒ ~1.8M battles) — so compute once per league per
gamemaster version and **cache to disk** (turn PvPoke's server precompute into our
first-run precompute). This same matrix is the substrate M3/M4 need, so M6 and M3 share it.

---

## 3. Architecture for the new work

### 3.1 New files (proposed)
```
PokeParty/Models/
  Team.swift                 // Team, TeamMember (Codable, for persistence + sharing)
PokeParty/Engine/
  TeamAnalyzer.swift         // Milestone 1: matrix → grades/threats/teammates (uses Battle 1v1)
  Consistency.swift          // port of calculateConsistency() (or add to BattlePokemon/Pokemon ext)
  ThreeVThreeBattle.swift    // Milestone 2: true 3v3 sim with switching (new)
  TeamMatchup.swift          // result types for 3v3 (winner, margin, shields/HP remaining)
PokeParty/Engine/Meta/
  MetaPool.swift             // generateFilteredPokemonList port (min stat product, filters)
  RankerScenario.swift       // leads/closers/switches/chargers/attackers
PokeParty/Store/
  TeamBuilderModel.swift     // @Observable: current team (3 slots), moveset selections, results
  TeamFinderModel.swift      // @Observable: candidate pool + finder run state/progress (Milestone 3+)
PokeParty/Views/TeamBuilder/
  TeamBuilderView.swift      // middle column: 3 slots + add mon + moveset pickers
  TeamGradesView.swift       // A–F cards (Coverage/Bulk/Safety/Consistency) + threat score
  TeamThreatsView.swift      // threats list + suggested teammates
  TeamTypingView.swift       // offense/defense type coverage grid (nice-to-have)
```

### 3.2 Sidebar / navigation wiring
- Extend `SidebarSelection`:
  `case teamBuilder` (and later `case teamFinder`, `case bestTeams`).
- Add rows under the "Tools" section in `LeagueSidebar.swift`.
- Add branches in `ContentView`'s `content`/`detail` @ViewBuilders. Inject
  `RankingsStore` (data hub) + new `TeamBuilderModel`.
- Team builder respects the currently selected `RankingsStore.format` (league/cup) so
  the meta pool and grades match what the user is browsing. Add a format picker inside
  the team builder too (independent of the sidebar league selection) — TBD, see Q1.

### 3.3 Concurrency / performance strategy
- **Determinism is our friend:** every 1v1 is pure given inputs → embarrassingly parallel.
- **Milestone 1 (analysis):** meta×3 ≈ a few hundred–thousand 1v1s per team. Run off the
  main actor with `TaskGroup` (chunked) or `DispatchQueue.concurrentPerform`. Cache
  `optimalStats` per (speciesId, moveset, cpCap, levelCap) — it's the expensive part.
  Precompute the meta's `Stats` + `BattlePokemon` templates **once** per format.
- **Milestone 2 (single 3v3):** synchronous is fine; one battle.
- **Milestone 3+ (finder / best teams):** this is the "massive" part.
  - Pipeline: (a) build combatant templates once; (b) precompute the full **1v1 matrix**
    of the candidate pool (N×N ratings, all shield scenarios) — this is the reusable
    substrate; (c) run 3v3s using cached 1v1 outcomes where possible.
  - Parallelize with `TaskGroup`/`concurrentPerform` first (CPU). Profile.
  - **GPU (Metal) is a later optimization** and only worth it if the 3v3 inner loop can be
    made branch-light. The current `Battle`/`ActionLogic` is heavily branchy (poor GPU fit).
    Realistic GPU path = precompute the N×N 1v1 rating matrix (still CPU, it's branchy), then
    do the **team-vs-team aggregation / search** (matrix reductions, ranking) on GPU. Treat
    GPU as Milestone 5; get correctness + CPU parallelism first. Do **not** prematurely
    rewrite the branchy sim for Metal.
  - Combinatorics reminder: choosing teams of 3 from a pool of P is C(P,3) teams; all-vs-all
    is ~C(P,3)²/2 team matchups. For P=50 that's ~19.6k teams and ~192M matchups — must
    prune (use the 1v1 matrix + heuristics, restrict pool to meta relevance, sample, or
    beam-search) rather than brute force.

---

## 4. Milestones (build order)

### ✅ Milestone 0 — Plan & recon  *(this document)*

### ▶ Milestone 1 — Team Builder view + team analysis (matches website)
Reuses the existing 1v1 engine. No new battle mechanics.
1. `Team`/`TeamMember` models.
2. `TeamBuilderModel` (`@Observable`): 3 slots, per-slot species + fast/charged move
   selection (reuse `MoveSelectorRow`), selected format.
3. `MetaPool.swift`: port `generateFilteredPokemonList` (min stat product + filters).
4. `Consistency.swift`: port `calculateConsistency()`.
5. `TeamAnalyzer.swift`:
   - `analyze(team:format:store:) async -> TeamAnalysis`
   - Runs meta×3 1v1s (parallel, cached `optimalStats`), computes threats + `avgThreatScore`,
     the four grades, suggested teammates.
   - `struct TeamAnalysis { grades(coverage/bulk/safety/consistency), threatScore, threats:[ThreatEntry], suggestions:[SuggestionEntry], typing }`.
6. Views: `TeamBuilderView` (compose), `TeamGradesView` (A–F cards), `TeamThreatsView`
   (threats + suggestions). Reuse `TypeBadgeRow`/`RatingBar`/`ScoreBadge`.
7. Sidebar + ContentView wiring (`.teamBuilder`).
8. **Safety grade**: implement via §2.9 option (A) — fetch switches-category rankings.
   If not yet wired, stub Safety with default 60 and mark TODO (still shows a grade).
9. Verify a known PvPoke team reproduces the same grades/threats within rounding.

### Milestone 2 — True single 3v3 battle (two specific teams)
The foundation for the finder. New engine layer above `Battle`.
1. `ThreeVThreeBattle.swift`:
   - Inputs: team A (3 `Combatant` + stats), team B, leads (indices), shield counts (2 each),
     AI/switch settings.
   - Models: lead selection, **switching** (carry HP/energy/shields/buffs via
     `BattlePokemon.start*` knobs), the **switch timer** (post-switch cooldown), farming down,
     end-of-battle margin. Port from PvPoke `Battle.js` team mode + `ActionLogic` switch logic.
   - Output `TeamMatchup { winner, marginRating, survivorsA/B, shieldsLeft, log? }`.
2. Deterministic AI for switch decisions (start simple: no mid-battle switching / "safe swap"
   heuristic, then improve). Document divergences from PvPoke.
3. Unit tests vs a couple of hand-checked or PvPoke-sim'd 3v3 outcomes.
4. Small dev UI to pick two teams and see the result + timeline (optional, behind a debug flag).

### Milestone 3 — Advanced Team Finder
1. `TeamFinderModel`: user picks 3–N mons (up to whole meta). Generate candidate teams of 3
   (`C(N,3)`), dedupe by family/role, respect cup slot/point rules if any.
2. Score each candidate team by simulating (Milestone 2) against a **reference opponent set**
   (the meta, or the other candidate teams). Aggregate win rate / margin.
3. **Parallelize** (TaskGroup/concurrentPerform), progress reporting, cancellation.
   Precompute 1v1 matrix substrate; prune aggressively (see §3.3).
4. UI: pool picker, "Find teams" with progress, ranked results with per-team breakdown.

### Milestone 4 — Best Teams (simulate the whole meta 3v3)
1. Run all (pruned) meta teams vs all — round-robin or Swiss/beam to cut combinatorics.
2. Rank teams by aggregate performance. Cache results per format (SwiftData) — expensive.
3. UI: leaderboard of top teams, filters.

### Milestone 5 — GPU / heavy parallelization (only if needed)
1. Profile CPU parallel version first; identify the real bottleneck.
2. Likely target: N×N 1v1 rating matrix as the substrate, GPU-accelerate the **search/
   aggregation** over that matrix (not the branchy per-turn sim).
3. Investigate whether a simplified, branch-reduced 1v1 kernel is worth a Metal port.
4. Persist/precompute matrices server-side or on first launch if it's a fixed meta.

### Milestone 6 — Self-hosted rankings (remove online-seeded values)
Goal: the Team Builder depends only on `gamemaster.json`, never on PvPoke's precomputed
`rankings-{cp}.json`. See §2.11 for the four borrowed values. Build in this order so each
step removes a dependency and de-risks the next; **this is also the substrate M3/M4 need**,
so do M6.1–M6.2 before/with M3.
1. **M6.1 — `MetaPool`** (`Engine/Meta/MetaPool.swift`): port `generateFilteredPokemonList`
   (min stat-product per league + released/eligibility/tag filters). Removes the "which
   mons" dependency; the analyzer builds candidates from this instead of the ranking list.
   *Self-contained, cheap.*
2. **M6.2 — Local `Ranker`** (`Engine/Meta/Ranker.swift` + `RankerScenario.swift`): run the
   N×N matrix across the 5 scenarios (§2.10), iterate with opponent-relevance weighting,
   normalize to 0–100 per category. Produces per-mon category scores (incl. **switches →
   Safety**) and the overall order (→ **meta-relevance**). **Cache to disk** per
   (league, gamemaster-version); recompute in the background on gamemaster change.
   Expensive — reuse the fast 1v1 path + the M3 matrix substrate.
3. **M6.3 — Moveset auto-selection** (`Engine/Meta/MovesetSelector.swift`): port PvPoke's
   per-mon moveset optimization so we no longer read recommended movesets. Hardest; until
   done, the ranking movesets remain a fine stand-in.
4. **M6.4 — Cut the cord / offline mode:** switch `TeamAnalyzer` + `TeamBuilderModel` to the
   local Ranker outputs; keep the online rankings only as an optional cross-check. Validate
   locally-computed grades/threats match the pvpoke.com-seeded ones.

### Milestone 7 — Interactive Battle Viewer (1v1 & 3v3 timeline)
Show a battle as a **scrubbable key-frame timeline** with **residuals** (HP / energy /
shields / buff stages at each frame), the moves thrown, shields used, and faints. Build the
1v1 viewer first; 3v3 reuses it. This is where the "no UI for the simulator" gap gets closed.

**Prerequisite — engine instrumentation (opt-in, OFF by default):**
`Battle` today runs to completion and only exposes the final `battleRating`. Add an opt-in
recording mode — e.g. `Battle(a, b, record: true)` — that appends a frame at each key event.
It must stay off in the analyzer/finder hot loops (perf). New `Engine/BattleLog.swift`:
- `enum BattleEventKind { fast, charged, shield, faint, switchIn, timeout }`
- `struct BattleEvent { actor: Int; kind; moveId: String?; damage: Int?; shielded: Bool }`
- `struct BattleFrame { turn: Int; timeMs: Int; hp: [Int]; energy: [Int]; shields: [Int]; buffs: [[Int]]; event: BattleEvent? }`
- `struct BattleLog { frames: [BattleFrame]; ratingA/ratingB; residuals (hp/energy/shields left both sides) }`

`ThreeVThreeBattle` records each segment with `record: true` and stitches them into a
`TeamBattleLog { segments: [BattleLog]; switches; result: TeamBattleResult }` with switch
markers between segments.

**Views (`PokeParty/Views/Battle/`):**
- `BattleTimelineView` — reusable 1v1 viewer: a horizontal key-frame strip (a tick per event,
  colored by actor / move type), a scrubber, HP/energy/shield bars that reflect the selected
  frame, and an event list. "Residuals" = the final frame's remaining HP/energy/shields.
- `TeamBattleView` — 3v3: result header (winner, survivors, margin), the entrance/switch
  order, and per-segment `BattleTimelineView`s (or one continuous stitched timeline).

**Entry points (navigation):**
1. **1v1** — from `PokemonDetailView`'s **Battle Simulator**: tapping a simulated matchup row
   opens its `BattleTimelineView` (re-runs just that matchup with `record: true`). Also from
   the Team Builder **threat matrix** — tap a cell → that member-vs-threat timeline.
2. **3v3** — in the **Team Builder**: your team is Team A; add an **opponent team** (reuse the
   same add/edit cards), then a **"Battle"** button opens `TeamBattleView`. (This supersedes
   the M2 "dev UI" item.) A standalone sidebar "Battle" tool for arbitrary team-vs-team is a
   later option.

**Notes:** recording is per-battle and cheap when off — never enable it in the
analyzer/finder loops. Determinism means every timeline is exactly reproducible (good for
snapshot tests and caching).

### Milestone 8 — Optimal-play battle search (shield & switch decisions)
Today a battle is ONE deterministic AI-vs-AI playthrough: `ActionLogic.wouldShield` makes a
greedy shield choice and switching is faint-only / best-matchup. Real optimal play depends on
*when* each side shields and *when/whether* it switches — and it's a two-player game, so the
"right" answer is game-theoretic (each side plays its best line against the other). This
milestone turns the single playthrough into a search over both sides' shield & switch
decisions. Motivating case: "shielding the first charged move isn't always ideal."

**Decision space:**
- Shields: at each incoming charged move, shield or not (until the 2-shield pool is spent).
- Switches: at each turn, stay or switch to a specific teammate (subject to the switch timer);
  the lead choice is the first switch decision.
- Two-sided & simultaneous → not a simple max; solve as minimax / a per-decision matrix game.

**Architectural prerequisite:** the battle must be *branchable* — clone full battle state at a
decision point and explore both branches. `BattlePokemon.clone()` exists; we also need to
snapshot the `Battle`'s own turn state (or reimplement the loop functionally) and a way to
*inject* shield/switch decisions (override `ActionLogic`) so the searcher drives them.

**Leads are fixed (design decision):** the first Pokémon on each team IS the lead (set via
UI order — the team cards already show `LEAD` on index 0 and reorder; the opponent's
first-added is its lead). Do NOT enumerate the 3×3 lead matrix — it's wasted compute and not
the question being asked. The question is "*this lead with these two behind vs theirs — who
wins?*"

**Imperfect information (design principle):** the AI must decide from REVEALED Pokémon only —
never from the opponent's hidden backline. Reacting to the mon currently on the field (e.g.
best-matchup replacement on faint) is legitimate; proactively switching a *neutral* lead to a
back-line counter because we "know" a good matchup is hidden there is NOT — a real player
wouldn't switch until that threat is revealed. So voluntary switching (M8.3) must run on a
per-player *perceived* view of the battle, not the full team knowledge the simulator has.

**M8.3 switching model (detailed spec — agree before coding):**

*Knowledge each side has:*
- Its OWN full team (3 species + movesets) — you built it.
- The opponent's Pokémon only once **revealed** (has entered the field). The hidden backline
  is unknown: unknown count-remaining is known (3 minus revealed), but not which species.
- Simplification: a revealed mon's moveset is treated as known (standard PvPoke assumption).
  Note it; refine to "known once used" later if needed.

*Perceived state:* the switch AI for side X sees only `{X's full team state} ∪ {revealed
opponent mons + the on-field opponent}`. It must NOT read unrevealed opponent mons. Implement
as an explicit `PerceivedState` passed to the decision function, not the full battle.

*When a voluntary switch is considered (decision points):* not every turn (too costly, and
GBL play is chunky). Evaluate at: (a) each **reveal boundary** (a new opposing mon comes in),
and (b) when the active mon crosses a "losing" threshold (projected to lose the current 1v1).
Free switch on faint stays as-is.

*The decision (reactive, revealed-only):* switch active→backup only if, against the
**currently-revealed** opponent, a backup wins by a margin exceeding a hysteresis threshold AND
the current matchup is unfavorable. Explicitly forbidden: switching a *neutral/winning* lead to
pre-counter a hidden backline (the case the user called out). You react to what's on the field.

*Switch cost:* switching hands the opponent tempo — the incoming mon enters at an energy
deficit. Model with the `switches` RankerScenario energy (opponent ≈ +4 fast-moves of energy;
§2.10) applied to the incomer. Add a **switch timer**: after switching you can't switch again
for the GBL cooldown window (track in battle-ms).

*Tractability:* a full imperfect-information Nash solve (belief states over hidden mons) is out
of scope. Use a deterministic reactive heuristic per side on the perceived state; optionally a
shallow search over switch/no-switch at the (few) decision points. Document divergence from
real optimal play.

*Architectural note (important):* the current 3v3 is **segment-based** — each segment runs a
full 1v1 to a faint, so switches can only happen on faint today. Voluntary switching happens
*mid-1v1*, which this structure can't express. Two options: **(a)** restrict voluntary switches
to **reveal boundaries** (start of a segment) — fits the segment model, cheap, captures
"switch when they bring in X"; **(b)** rewrite the orchestrator to a **turn-driven loop**
(ties into M8.1 branchable battle) where either side may switch at any decision turn — full
fidelity, larger lift. Recommend shipping (a) first, then (b).

**Phased approach:**
1. **M8.1 — Branchable battle:** clone/restore full `Battle` state + a `DecisionPolicy` hook
   that lets a caller force shield yes/no and switch choices instead of the heuristic.
2. **M8.2 — 1v1 shield search:** branch shield decisions for both sides; solve the small matrix
   game (or minimax + alpha-beta) → best-line rating + optimal shield sequence. Fixes the
   "shield the first" problem.
3. **M8.3 — Switch search (3v3):** add lead + voluntary-switch branching (with the switch
   timer) on top of M8.2; minimax over the combined shield+switch tree with pruning.
4. **M8.4 — Aggregation & perf:** define the value a two-sided search reports (minimax value /
   margin); memoize identical sub-positions; cap depth/breadth; parallelize.

Supersedes the M2 "voluntary switching + switch timer" and "best-matchup" heuristic items.
Cost is high, so the finder/rankings (M3/M4) may use a cheaper scenario approximation while the
head-to-head viewer uses the full solver — see Q6/Q7.

---

## 5. Open questions (resolve as they block work)
- **Q1 — Format source:** does the team builder follow the sidebar's selected league/cup,
  or have its own independent format picker? (Leaning: its own picker, defaulting to the
  sidebar selection.)
- **Q2 — Safety grade data:** ✅ RESOLVED. The overall rankings we already download carry a
  per-mon `scores` array; Safety reads `scores[2]`. Fully offline computation is M6.2.
- **Q3 — Team persistence/sharing:** SwiftData-persisted saved teams? Import/export via
  PvPoke team codes (their URL/pastebin format)? Nice-to-have, not blocking M1.
- **Q4 — 3v3 AI fidelity:** how faithful must switch AI be to PvPoke? Start with a simple
  heuristic and document divergence; refine later.
- **Q5 — Finder pool size default:** cap for "up to 10 or whole meta?" and the pruning
  strategy — affects whether M3 is usable without M5.
- **Q6 — Battle search depth (M8):** full minimax over all shield+switch decisions (accurate,
  expensive) vs scenario enumeration/averaging (cheap, approximate). Leaning: full solver for
  the head-to-head viewer; start with 1v1 shield search (M8.2) which both approaches need.
- **Q7 — Where the solver applies:** head-to-head viewer only (viewer accurate, finder/rankings
  keep the fast heuristic) vs everywhere (consistent but the finder gets much more expensive).
  Leaning: viewer now, decide the finder's fidelity at M3.

## 6. Validation strategy
- Cross-check Milestone 1 grades/threats/teammates against pvpoke.com for 3–5 known teams
  per league; expect exact-to-rounding on grades since we ported the constants.
- Unit-test the pure pieces: `calculateConsistency`, `letterGrade`, threat score transform,
  `avgThreatScore` selection, meta pool filtering.
- Keep the existing 1v1 engine as the trusted oracle; every higher layer is deterministic
  and testable.

---

## Milestone checklist (claim before starting)
- [x] M0 — Plan & recon (this doc)
- [x] M1.1 — `Team` / `TeamMember` models (`Models/Team.swift`)
- [x] M1.2 — `TeamBuilderModel` (`Store/TeamBuilderModel.swift`)
- [x] M1.3 — Meta pool — uses the loaded ranking list directly (approx of `generateFilteredPokemonList`; a dedicated `MetaPool` with the min-stat-product filter is still TODO)
- [x] M1.4 — `Consistency` port (`Engine/Consistency.swift`) — **exact** byte-for-byte port of PvPoke's `calculateConsistency`. Also aligned `BattleMove.selfAttackDebuffing`/`selfDefenseDebuffing` with PvPoke's broad definition (any negative buff), which the move-ordering & shield AI use too.
- [x] M1.5 — `TeamAnalyzer` (grades/threats/teammates, parallel) (`Engine/TeamAnalyzer.swift`)
- [x] M1.6 — Team builder views (`Views/TeamBuilderView.swift`, `Views/TeamAnalysisView.swift`) — compose + grades + threats + suggestions. Moveset editing per-slot still TODO (uses recommended movesets).
- [x] M1.7 — Sidebar + ContentView wiring (`.teamBuilder`)
- [x] M1.8 — Safety grade data — **done**. The overall rankings JSON we already download contains a per-mon `scores` array; `RankingEntry.switchesScore` reads index 2 (switches), and the Safety grade averages it (60 fallback per unranked mon, like PvPoke). No extra fetch needed.
- [ ] M1.9 — Validate grades/threats/teammates against pvpoke.com; verify parallel analysis stays off the main thread
- [ ] M1.x — In-team-builder format picker (plan Q1); currently follows the sidebar's last-selected league via `store.format`
- [~] M2 — True single 3v3 battle engine — **engine done + unit-tested**; refinements pending
  - [x] `ThreeVThreeBattle` orchestrator (`Engine/ThreeVThreeBattle.swift`) + `TeamBattleResult`
  - [x] Engine hooks: `BattlePokemon.startHp`, `Battle(startTime:)` (both backward-compatible; 1v1 unchanged)
  - [x] Unit tests (`PokePartyTests/ThreeVThreeBattleTests.swift`, Swift Testing, synthetic data — 4/4 pass)
  - [x] Voluntary mid-battle switching + switch timer → done under **M8.3** (`voluntarySwitching`, opt-in)
  - [x] Best-matchup switch selection — `SwitchPolicy.bestMatchup` (default): on faint, brings in the alive teammate that scores best vs the opponent's current state (via `BattlePokemon.clone()` throwaway sims). `.teamOrder` still available. Tested.
  - [ ] Continuous per-mon cooldown across a switch (currently resets each segment)
  - [ ] Dev/head-to-head UI to pick two teams and view the result/timeline → folded into **M7**
  - [ ] Validate a few outcomes against pvpoke.com's battle sim
- [~] M3 — Advanced Team Finder
  - [x] M3-lite — **Simplistic 3v3 Party Finder** (2026-07-10): quick suggested teams per format
    from true 3v3 sims. `Engine/TeamFinder.swift` (all C(pool,3) combos from the top of the
    ranking list, family/species-deduped, each scored vs a deterministic stride-sampled set of
    ~24 opponent teams; fast heuristics per Q7 — greedy shields, faint-only best-matchup
    switching, NO shield search), `Store/TeamFinderModel.swift` (own format picker incl. cups,
    pool size 10–25, progress + cancellation), `Views/TeamFinderView.swift` (config +
    ranked-results columns, "Open in Team Builder"), sidebar `.partyFinder`. Unit-tested
    (`TeamFinderTests`). Still TODO for full M3: user-picked pools, bigger pools/pruning,
    per-team breakdown UI.
  - [x] M3 finder methods (2026-07-23) — the Party Finder now offers three methods
    (`TeamFinderModel.Method`): **Tournament** (round-robin 3v3s over a coverage-seeded
    field, now with a per-family diversity cap — `maxFieldSharePerFamily` — so one apex mon
    can't monopolize the field), **AAAA grade check** (`Engine/GradeFinder.swift`: grades
    every C(pool,3) trio with the Team Builder's exact formulas from one pairwise 1v1
    matrix — no 3v3 sims; ranked by worst category so AAAA teams lead), and **Combined**
    (AAAA teams seed the tournament field via `findTeams(seededField:)`). Tournament
    battles gain opt-in `voluntarySwitching` (M8.3 counterswaps/escapes) and
    `optimalShields` toggles; pool sizes up to 250; `Candidate.switchesScore` feeds the
    Safety grade. Unit-tested (`TeamFinderTests`: GradeFinder ranking, safety fallback,
    seeded-field bypass).
- [ ] M4 — Best Teams
- [ ] M5 — GPU / heavy parallelization
- [ ] M8 — Optimal-play battle search (shield & switch decision search / minimax)
  - [x] M8.1 — Shield-decision injection hook: `Battle.shieldOverride((defenderIndex, opportunityIndex) -> Bool?)` forces a shield decision (nil = heuristic). Tested.
  - [x] M8.2 — 1v1 shield-decision search (`Engine/ShieldSearch.swift`): enumerates each side's shield timings (subsets of the first `shields+2` opportunities), builds the payoff matrix, solves maximin (A) / best-response (B). `Solution` also reports the **win/loss/tie distribution across all distinct shield scenarios** + best/worst-case rating. `optimal()` / `optimalLog()`; `RankingsStore.battleReplay` returns log + scenario stats. Wired into the 1v1 Battle Simulator, which now shows optimal (not greedy) shielding **and a "9W · 2L of 11 shield scenarios · best/worst" stat row**. Tested.
  - [x] M8.3 — 3v3 optimal shields + information-aware switching. Leads UI-designated (position 0, `LEAD` badge on both teams) — NO lead enumeration.
    - [x] Optimal shields per 3v3 segment: `ShieldSearch.optimalPolicy(a,b)` solves the shield game from each segment's current carried state (on clones); `ThreeVThreeBattle.optimalShields` (default on) applies it. Information-legitimate (decides shields for the revealed matchup only). Head-to-head `TeamBattleView` now uses it.
    - [x] Information-aware *voluntary* switching. Phase (a): reveal-boundary switches within the segment model — `ThreeVThreeBattle.voluntarySwitching` (turn-0 safe-swap + counter-switch when the opponent reveals a mon), revealed-info only (`voluntarySwitchTarget` never reads the hidden backline), a **30s switch timer** (`switchTimerMs`, tunable — live game often cited as 60s), hysteresis (`switchHysteresis`), and a tempo/energy penalty on the stayer. Enabled in the head-to-head `TeamBattleView`. Tested (safe-swap picks the counter lead). Phase (b) **done (2026-07-23)** as two reveal-window mechanisms rather than a full turn-driven orchestrator: **counterswaps** (a side whose opponent just voluntarily switched — and is thus switch-locked — may punish with a dominant answer, `counterSwitchDominance`) and **mid-segment escapes** (`Battle.interruptCheck` stops a segment the moment a losing side's switch timer expires so the boundary logic can offer it a switch). Both tested.
    - [x] Per-segment shield-scenario stats surfaced in the 3v3: each `TeamBattleLog.Segment` carries its `ShieldSearch.Solution`, and `TeamBattleView` shows the "NW · ML of K shield scenarios · best/worst" row on each segment's timeline (reusing the 1v1 stat).
  - [~] M8.4 — Aggregation criterion + memoization + parallelism; decide finder fidelity (Q7). **Partial (2026-07-23):** `ShieldSearch` now memoizes payoff-matrix cells (a fought battle's rating covers every policy pair agreeing on the shield decisions that actually arose) and caches the 0–2-shield policy sets; the Party Finder exposes fidelity as user toggles (`simulateCounterswaps`, `optimalShields`) instead of a fixed Q7 answer. Still open: aggregation criterion for two-sided search values.
- [ ] M6 — Self-hosted rankings (remove online-seeded values; §2.11). Shares the 1v1-matrix substrate with M3.
  - [ ] M6.1 — `MetaPool` (min stat-product filter → own meta pool, not the ranking list)
  - [ ] M6.2 — Local `Ranker`: 5-scenario N×N matrix → category scores (Safety) + overall order (meta-relevance), cached to disk
  - [ ] M6.3 — Moveset auto-selection (stop reading recommended movesets)
  - [ ] M6.4 — Switch analyzer to local outputs; offline mode; validate vs pvpoke seeds
- [ ] M7 — Interactive Battle Viewer (1v1 & 3v3 key-frame timeline + residuals)
  - [x] M7.1 — `BattleLog`/`BattleFrame`/`BattleEvent` (`Engine/BattleLog.swift`) + opt-in `record` mode in `Battle` (`Battle(_,_,record:)`, off by default); `makeLog()` returns the timeline + residuals. Tested (frames time-ordered; fast/charged/faint events; off by default).
  - [x] M7.2 — `BattleTimelineView` (`Views/Battle/BattleTimelineView.swift`): **two synced lanes, one per Pokémon** (fixed name labels + column-aligned event ticks: short=fast, tall=charged, ✕=faint), scrubbable (tap tick / slider / step), per-side HP/energy/shield residual bars, event text. Derives max-HP from the initial frame. `BattleParticipant` display struct reused by 3v3. Verified via `#Preview`/RenderPreview.
  - [~] M7.3 — 1v1 entry point: **done** from `PokemonDetailView` — tap any Key Wins/Counters row → sheet re-runs that matchup with `record:true` (`RankingsStore.battleLog(...)`) → `BattleTimelineView`. Still TODO: tapping a Team Builder threat-matrix cell → timeline.
  - [x] M7.4 — `TeamBattleLog` recording in `ThreeVThreeBattle`: `runRecorded()` / static `runRecorded(...)` capture a `BattleLog` per 1v1 segment (with active team indices) + the result. `run()` refactored to a shared `simulateCore(record:)`. Tested.
  - [x] M7.5 — `TeamBattleView` (`Views/Battle/TeamBattleView.swift`): pick an opponent team (search + tap, recommended movesets), "Simulate Battle" runs the recorded 3v3 off-main, shows the outcome (winner / survivors / timed-out) and each segment as a `BattleTimelineView`. Entry: **"Battle" button** in `TeamBuilderDetailView` → sheet. Opponent team + runner live on `TeamBuilderModel`.

### Milestone 1 status note (2026-07-03)
Builds cleanly. The Team Builder is wired into the sidebar and produces the four
grades + threat score + top-threats matrix + suggested teammates, reusing the 1v1
engine via `MatchupSimulator` with the same off-main `TaskGroup` fan-out pattern as
`RankingsStore.simulateMatchups` (Swift-5-mode MainActor-isolation warnings match the
existing code). Known approximations, all marked in-code and above: Consistency
(M1.4), Safety (M1.8), meta-relevance = top-40 of rankings, and meta pool = ranking
list. Next best steps: M1.8 (real Safety data), M1.9 (validate vs website), then M2.
