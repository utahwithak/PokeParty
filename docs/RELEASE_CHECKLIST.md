# Release Checklist

## Refresh bundled seed data

`PokeParty/Resources/seed_*.json` are snapshots of PvPoke's data bundled into
the app so a fresh install (or a cleared cache) works offline before any
network call succeeds — see `DataService.seedBundledDataIfNeeded()`. They're
only ever a first-launch fallback (the real fetch still runs on top of them),
but a snapshot that's many months stale defeats the point. Refresh before
each release:

```sh
curl -o PokeParty/Resources/seed_gamemaster.json https://pvpoke.com/data/gamemaster.json
curl -o PokeParty/Resources/seed_rankings_1500.json https://pvpoke.com/data/rankings/all/overall/rankings-1500.json
curl -o PokeParty/Resources/seed_rankings_2500.json https://pvpoke.com/data/rankings/all/overall/rankings-2500.json
curl -o PokeParty/Resources/seed_rankings_10000.json https://pvpoke.com/data/rankings/all/overall/rankings-10000.json
```

Cups (limited-time formats) aren't bundled since they rotate — a stale one
would be actively misleading, so those stay live-fetch-only.

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
