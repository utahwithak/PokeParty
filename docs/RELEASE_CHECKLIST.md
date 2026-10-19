# Release Checklist

## Refresh bundled seed data

`PokeParty/Resources/seed_*.json` are snapshots of PvPoke's data bundled into
the app so a fresh install (or a cleared cache) works offline before any
network call succeeds — see `DataService.seedBundledDataIfNeeded()`. They're
only ever a first-launch fallback (the real fetch still runs on top of them),
but a snapshot that's many months stale defeats the point. Refresh before
each release:

```sh
BASE=https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data
curl -o PokeParty/Resources/seed_gamemaster.json "$BASE/gamemaster.json"
curl -o PokeParty/Resources/seed_rankings_1500.json "$BASE/rankings/all/overall/rankings-1500.json"
curl -o PokeParty/Resources/seed_rankings_2500.json "$BASE/rankings/all/overall/rankings-2500.json"
curl -o PokeParty/Resources/seed_rankings_10000.json "$BASE/rankings/all/overall/rankings-10000.json"
```

(Sourced from PvPoke's GitHub repo, not the live site — see `DataService.swift`'s
header comment for why.)

Cups (limited-time formats) aren't bundled since they rotate — a stale one
would be actively misleading, so those stay live-fetch-only.

## Bundle precomputed local rankings

Computing the local rankings takes about a minute of background CPU on first
launch. Shipping the result avoids that for new installs. A seed only helps
while its gamemaster hash matches the data in use, so do this *after*
refreshing the seed data above:

1. Run a Debug build with a clean cache (delete the app's
   `Application Support/PokeParty/LocalRankings` folder) and let the sidebar's
   "Updating local rankings…" finish.
2. Settings → Ranking Order → "Reveal Local Rankings Cache" (DEBUG only).
3. Copy `all-1500.json`, `all-2500.json`, `all-10000.json` into
   `PokeParty/Resources/` as `seed_local_ranking_1500.json`, `…_2500.json`,
   `…_10000.json`. `LocalRankingBuilder` loads them automatically.

## Build & test

- [ ] Bump the version/build number.
- [ ] Run the full test suite (`RunAllTests` / Cmd-U) on both macOS and iOS.
- [ ] Build and smoke-test both platforms (macOS + iOS) — check the Party
      Finder, Bench, and Scan tool (macOS-only) at minimum.
- [ ] Refresh the bundled seed data (above) if it's been more than a
      couple months since the last refresh, or PvPoke has published a known
      balance change / new season since.
- [ ] Verify in-app purchase gating: build a Release configuration (not
      Debug) and confirm `EntitlementStore.isUnlocked` starts `false` —
      Party Finder, Team Optimizer, and the Scan tool should show the
      paywall until a real purchase/restore succeeds. `EntitlementStore.swift`
      hardcodes `true` under `#if DEBUG` for convenience; double-check the
      `#else` branch hasn't regressed to `true` too (it did once already).

## Ship

- [ ] Archive and upload.
- [ ] Tag the release commit.
