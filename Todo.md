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
- [ ] support sorting the rankings
- [ ] Add Shadow toggle to bench pokemon and scanning
- [ ] shorten scaning time to every 2 seconds
- [ ] confirmation to remove pokemon from bench
- [ ] when scanning don't show pokemon of a lesser evolution for the breed
- [ ] running a tournament on iOS doesn't show the results. 
- [ ] 

## Future
- [ ] Add a super-advanced mode to edit move data and availability, then simulate against it
