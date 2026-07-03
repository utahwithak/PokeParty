# 3v3 Team Building & Simulation — Implementation Plan

> **Status:** Living document. Multiple agents may work from this. Check the
> **Milestone checklist** at the bottom and claim a task by marking it
> `[~] (in progress — <agent/initials>)` before starting, `[x]` when done.
>
> Last updated: 2026-07-03

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

---

## 5. Open questions (resolve as they block work)
- **Q1 — Format source:** does the team builder follow the sidebar's selected league/cup,
  or have its own independent format picker? (Leaning: its own picker, defaulting to the
  sidebar selection.)
- **Q2 — Safety grade data:** fetch PvPoke's `switches` rankings (§2.9-A, matches site
  exactly, needs network) vs recompute locally (offline, bigger). Milestone 1 uses (A).
- **Q3 — Team persistence/sharing:** SwiftData-persisted saved teams? Import/export via
  PvPoke team codes (their URL/pastebin format)? Nice-to-have, not blocking M1.
- **Q4 — 3v3 AI fidelity:** how faithful must switch AI be to PvPoke? Start with a simple
  heuristic and document divergence; refine later.
- **Q5 — Finder pool size default:** cap for "up to 10 or whole meta?" and the pruning
  strategy — affects whether M3 is usable without M5.

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
- [~] M1.4 — `Consistency` port (`Engine/Consistency.swift`) — **APPROX**, not yet byte-for-byte; finish the exact port
- [x] M1.5 — `TeamAnalyzer` (grades/threats/teammates, parallel) (`Engine/TeamAnalyzer.swift`)
- [x] M1.6 — Team builder views (`Views/TeamBuilderView.swift`, `Views/TeamAnalysisView.swift`) — compose + grades + threats + suggestions. Moveset editing per-slot still TODO (uses recommended movesets).
- [x] M1.7 — Sidebar + ContentView wiring (`.teamBuilder`)
- [ ] M1.8 — Safety grade data — **PROVISIONAL** (uses PvPoke's default 60). Fetch `rankings/{cup}/switches/rankings-{cp}.json` and read `scores[2]`.
- [ ] M1.9 — Validate grades/threats/teammates against pvpoke.com; verify parallel analysis stays off the main thread
- [ ] M1.x — In-team-builder format picker (plan Q1); currently follows the sidebar's last-selected league via `store.format`
- [ ] M2 — True single 3v3 battle engine
- [ ] M3 — Advanced Team Finder
- [ ] M4 — Best Teams
- [ ] M5 — GPU / heavy parallelization

### Milestone 1 status note (2026-07-03)
Builds cleanly. The Team Builder is wired into the sidebar and produces the four
grades + threat score + top-threats matrix + suggested teammates, reusing the 1v1
engine via `MatchupSimulator` with the same off-main `TaskGroup` fan-out pattern as
`RankingsStore.simulateMatchups` (Swift-5-mode MainActor-isolation warnings match the
existing code). Known approximations, all marked in-code and above: Consistency
(M1.4), Safety (M1.8), meta-relevance = top-40 of rankings, and meta pool = ranking
list. Next best steps: M1.8 (real Safety data), M1.9 (validate vs website), then M2.
