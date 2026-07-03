# PokeParty

A native macOS app (SwiftUI) for Pokémon GO PvP — rankings, IV checking, and a
local battle simulator. Built as a Mac-first reimagining of
[PvPoke](https://pvpoke.com), with the long-term goal of running large-scale
3v3 team simulations locally.

## Features

- **Rankings browser** — browse PvPoke's rankings for Great, Ultra, and Master
  League, plus any currently active limited cups (e.g. Summer Cup), in a
  three-column Mac-native layout. Per-Pokémon detail shows stats, recommended
  moveset, key wins, and counters.
- **Battle simulator** — a full Swift port of PvPoke's 1v1 battle engine
  (turn loop, damage/type math, shield & charged-move AI, shadows, Mimikyu's
  Disguise). Simulate any Pokémon against its entire league meta at any shield
  scenario (0/1/2 per side) with a custom moveset, in ~0.3 s. Validated against
  PvPoke's published ratings (median error 13 rating points, ~90% win/loss
  agreement).
- **IV Rank Checker** — enter a Pokémon's IVs and see its rank and stat-product
  percentage across Little/Great/Ultra/Master for its whole evolution family,
  with configurable level caps (40/41/50/51).
- **Offline-friendly** — game data and rankings are fetched from pvpoke.com and
  cached persistently (SwiftData) with ETag revalidation, so the app works
  offline and only re-downloads when the data actually changes.

## Requirements

- macOS 14+ (built against a multiplatform SwiftUI target; macOS is the
  primary platform)
- Xcode 16+ to build

## Building

Open `PokeParty.xcodeproj` in Xcode and run the `PokeParty` scheme. The app
needs the **Outgoing Connections (Client)** App Sandbox entitlement (already
configured) to fetch data on first launch.

## Architecture notes

- `PokeParty/Engine/` — the battle engine: a pure-Swift, deterministic port of
  PvPoke's `Battle.js` / `ActionLogic.js` (simulate mode). No SwiftUI
  dependencies; matchup sweeps fan out across CPU cores with `TaskGroup`.
- `PokeParty/Services/` — data loading (`DataService` + SwiftData-backed
  `ResourceCache`) and IV math (`IVCalculator`, including the CPM table, which
  PvPoke hardcodes in JS rather than shipping in its JSON).
- `PokeParty/Store/` / `PokeParty/Views/` — observable state and the SwiftUI
  front end.

## Credits & license

MIT — see [LICENSE](LICENSE).

- Battle logic, ranking data, and game data come from
  [PvPoke](https://github.com/pvpoke/pvpoke) (MIT, © 2019 pvpoke). PokeParty
  fetches its data files from pvpoke.com at runtime and ports portions of its
  simulation code to Swift.
- PokeParty is an unofficial fan project and is not affiliated with PvPoke,
  Niantic, Nintendo, or The Pokémon Company. Pokémon and Pokémon character
  names are trademarks of Nintendo.
