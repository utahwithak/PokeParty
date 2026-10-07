# Todo

## Current
- [x] Move the refresh button to settings
- [x] Fix "Find Teams" button touch area on bench view on iOS (icon-only button had no minimum tap target; gave it a 44x44 hit area)
- [x] Add ability to customize hill climb tournament to not explore alternate movesets
- [x] Add AI to look for top vs. meta teams (meta field now weighted by rank, not equally)
- [x] Add ability to continue tournament results "against full meta teams" — after a hill climb, pit those teams against 2k-10k random meta teams to see which has the highest win rate
- [x] Move scan button to a tool with the first pane showing scan results/info and the detail pane showing the IV grid for the current scan results — also merged the two old scan sheets, added captured-date + duplicate detection, and an Unclassified bench bucket
- [x] Highlight the IV grid visually for different rankings when scanning (e.g. golden badge for 100%, hearts with different colors) — an easy way to spot a great mon/evolution at a glance
- [x] Explore reducing/eliminating dependence on pvpoke data to avoid hitting its data endpoint too much — ship with initial data? Bundled gamemaster + core league rankings as an offline seed; added docs/RELEASE_CHECKLIST.md to keep them fresh
- [x] Add IV selectors to 1v1 simulations
- [x] Add breakpoints vs. other metas (currently just Master League) — added a League picker (Great/Ultra/Master); the hero is now built at the CP-cap-legal level for each league instead of hardcoded level 50, and the power-up sweep clamps to that same legal max
- [ ] doing tournament on phone doesnt show results
- [x] support sorting the rankings — added a Sort picker above the rankings list matching PvPoke's own categories (Overall/Lead/Closer/Switch/Charger/Attacker/Consistency), backed by the per-entry `scores` sub-scores; the score badge shows the selected category's score, and each row still shows its true overall league rank regardless of sort order
- [x] Add Shadow toggle to bench pokemon and scanning — the bench editor already had a Shadow toggle (gated to shadow/shadow-eligible species); the Scan staging panel had none at all, so `ScanModel.StagedPick` now carries a `shadow` flag (defaulting from the scanned species, toggleable before confirming), threaded through `BenchStore.addFromScan`, with the same eligibility gating and a Shadow badge on the staged pick
- [x] shorten scaning time to every 2 seconds — `ScanModel.idleScanInterval` (the poll period while not actively auto-advancing) dropped from 4.5s to 2.0s
- [x] confirmation to remove pokemon from bench — both delete paths (list swipe action and the detail view's "Remove from Bench" button) now show a destructive confirmation dialog naming the Pokémon before deleting
- [x] when scanning don't show pokemon of a lesser evolution for the breed — `RankingsStore.family(for:excludingPreEvolutions:)` now drops strict ancestors of the scanned/bench species; wired into Scan grid, Bench unclassified grid, and auto-advance's rank check
- [ ] running a tournament on iOS doesn't show the results. 
- [x] remember which tab was selected across launches — `SidebarSelection` gained a stable `persistenceKey` (cup/league formats persist by their `id`, re-resolved against the loaded cup list on restore) saved to `UserDefaults` on every change and restored once the gamemaster/cups finish loading
- [x] Some evolutions are not showing up during scanning -> Shellos, far fetch'd. — root cause was Gastrodon's gamemaster entry missing its `family` object entirely; family grouping now built from a parent/evolutions link graph (not `family.id` equality), so a relative's declared link is enough even when a species' own entry is incomplete (also fixes the same latent gap for Type: Null/Silvally). Kantonian Farfetch'd itself doesn't evolve in GO, so it correctly stands alone.
- [x] breakpoints need to adapt to the league. for master 15/15/15 is always the best, but still I think it has to do with the IV ranking. For the other leagues, 15/15/15 is not the best usually. We should base breakpoints on the ranking, maybe the differences between having a rank 1, 20, 50, 100 vs 200. "If you have high rank <mon> it should beat <foo>, Or something like that. — added a "Compare as Rank" picker (1/20/50/100/200) that resolves that rank's real IV combination via `IVCalculator.rankedCombos` (its own optimal level under the CP cap, rarely 15/15/15 for capped leagues) and battles it against the top meta at 0/1/2 shields, shown as a new "As Rank N" section above the existing 12–15 IV grid
- [ ] Add a "Check Opponent" tab to the Team Builder — search for an opponent, see its common moveset + fast/charge move counts, and whether anyone on your current team beats it

## Future
- [ ] Add a super-advanced mode to edit move data and availability, then simulate against it
- [ ] Sync tournament results on iCloud as well — unlike the Bench, saved tournaments can include up to 10,000 teams across multiple runs, easily exceeding NSUbiquitousKeyValueStore's ~1MB total quota. Needs a decision: best-effort KVS sync (skip large runs), cap synced history to the N most recent runs, or a proper iCloud Documents container (a different, not-yet-granted entitlement that may hit the same provisioning wall noted for CloudKit on this dev team).
- [ ] Track real usage/popularity data for Pokémon in the meta (how often each is actually seen), not just PvPoke's simulated battle rankings — no current data source for this; would need a new feed or heuristic.
