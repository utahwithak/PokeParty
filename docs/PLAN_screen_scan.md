# Screen Scan Feature Plan

**Branch:** `feature/screen-scan`  
**Goal:** Let the user point their Mac at the Phone Mirroring app (showing a Pokémon's detail screen in Pokémon GO) and automatically populate a `BenchEntry` with the species name, CP, and a ranked list of IV candidates.

---

## Scope (Tier 1 — what this plan covers)

- macOS only, using ScreenCaptureKit + Vision OCR
- Reads: species name (from the "This {name} was caught…" message, so nicknames don't matter), level, max HP, and CP (best-effort — the gold CP badge OCRs unreliably) from the detail screen
- Produces: a candidate list of IV spreads, narrowed primarily by the HP IV solved from HP + level via the CPM table, with CP (when readable) as a secondary ±3 filter, ranked by stat product
- The user picks an IV spread (or defers) and a `BenchEntry` is added to `BenchStore`
- Moves are NOT scanned — the app defaults to the recommended moveset as it already does in `addFromRankings()`

Tier 2 (appraisal bar pixel analysis for exact IVs) is left for a later branch.

---

## New Files

| File | Purpose |
|---|---|
| `Services/ScreenScanner.swift` | ScreenCaptureKit capture + Vision OCR pipeline; pure `actor`, no UI |
| `Store/ScannerModel.swift` | `@Observable` model; owns scan state + candidate list; calls `ScreenScanner` and `IVCalculator` |
| `Views/ScannerSheet.swift` | Sheet UI: scan button, name/CP preview, IV candidate picker, confirm action |

---

## ScreenScanner.swift

```swift
// actor ScreenScanner
// - capturePhoneMirroringFrame() -> CGImage?
//     Find window via SCShareableContent where title contains "iPhone Mirroring"
//     or app bundle ID "com.apple.ScreenContinuity".
//     Use SCScreenshotManager.captureImage(contentFilter:configuration:) (macOS 14+).
//     Falls back to CGWindowListCreateImage for macOS 13 compatibility.
// - recognizeText(in: CGImage) async throws -> [VNRecognizedTextObservation]
//     VNRecognizeTextRequest with .accurate recognition level.
// - extractPokemonInfo(from: [VNRecognizedTextObservation]) -> PokemonScanInfo?
//     Name: regex "^This\s+(.+?)\s+was\s+caught\b" against the catch-message line
//     (reliable even if the Pokémon has a nickname); falls back to the old
//     largest-plausible-text heuristic if that line isn't visible.
//     Level: regex "Lvl\.?\s*(\d+(?:\.\d+)?)".
//     Max HP: regex "(\d+)\s*/\s*(\d+)\s*HP", second capture group.
//     CP: best-effort only — heuristic on "CP\s*(\d+)" — the gold CP badge
//     OCRs unreliably, so this is treated as a bonus signal, not required.
```

**Entitlement required:** `com.apple.security.screen-recording` in `PokeParty.entitlements`.  
ScreenCaptureKit will also prompt the user via system permission dialog on first use.

**macOS version:** `SCScreenshotManager` requires macOS 14.0. Add `@available(macOS 14, *)` guard or use `CGWindowListCreateImage` as fallback.

---

## ScannerModel.swift

```swift
// @MainActor @Observable final class ScannerModel
// 
// State:
//   var phase: ScanPhase  // .idle | .scanning | .results(ScanResult) | .error(String)
//
// struct ScanResult {
//   var name: String           // OCR'd Pokémon name (from catch message when available)
//   var cp: Int?                // OCR'd CP — best-effort, often nil
//   var level: Double?          // OCR'd level, from "Lvl XX"
//   var maxHP: Int?             // OCR'd max HP, from "X / X HP"
//   var matchedSpeciesId: String?  // fuzzy-matched from RankingsStore.allPokemon
//   var candidates: [IVCandidate]  // top IV spreads narrowed by HP+level (and CP if known)
// }
//
// struct IVCandidate: Identifiable {
//   var ivs: IVs
//   var rank: Int
//   var percent: Double
//   var level: Double
// }
//
// func scan(store: RankingsStore) async
//   1. ScreenScanner.capturePhoneMirroringFrame()
//   2. ScreenScanner.recognizeText(in:)
//   3. ScreenScanner.extractPokemonInfo(from:)
//   4. Fuzzy match name → speciesId (see below)
//   5. IVCalculator.rankedCombos(baseAtk:baseDef:baseHp:cpCap:) for the selected league,
//      filtered to combos whose hp IV matches the value(s) solved from
//      floor(cpm(level) * (baseHp + hpIV)) == scanned maxHP, then further
//      filtered to combos where combo.cp is within ±3 of scanned CP if CP was read;
//      take top 20 by rank
//   6. Set phase = .results(...)
//
// func confirm(candidate: IVCandidate?, addLeague: League, bench: BenchStore, store: RankingsStore)
//   Calls bench.addFromRankings(speciesId:store:league:)
//   Then if candidate != nil: sets entry.ivs = candidate.ivs and bench.update(entry)
```

**Fuzzy name matching:**
- Normalize both OCR output and `pokemon.speciesName`: lowercase, strip punctuation
- First try exact match after normalization
- Then `localizedCaseInsensitiveContains` substring match
- Fallback: Levenshtein distance ≤ 2, prefer shortest edit distance
- Handle known substitutions: "♀" → "-f", "♂" → "-m", "Mr." → "mr"
- Shadow Pokémon: game shows base name; scanner sets `shadow: false` (user can toggle in BenchDetailView)

---

## ScannerSheet.swift

```swift
// Sheet presented from BenchView toolbar button (label: "Scan", systemImage: "camera.viewfinder")
//
// Layout:
//   - Instruction text: "Open Phone Mirroring and navigate to a Pokémon's detail screen."
//   - "Scan" Button → model.scan(store:)
//   - While scanning: ProgressView
//   - On results:
//       - "Pokémon: [name]   CP: [cp]" — with mismatch warning if match confidence < threshold
//       - If matchedSpeciesId nil: text field to manually type name + search
//       - League picker (GL / UL / ML — determines which CP cap to use for candidates)
//       - List of top-10 IV candidates showing: rank, ivs (atk/def/hp), level, percent
//         Selected row highlighted; "None (set later)" as first option
//       - "Add to Bench" button → model.confirm(...)
//   - On error: error message + retry button
```

---

## Integration in BenchView.swift

Add to the `HStack` in `safeAreaInset(edge: .top)` (next to the existing "Find Teams" menu):

```swift
Button { showingScanner = true } label: {
    Label("Scan", systemImage: "camera.viewfinder")
        .labelStyle(.iconOnly)
        .font(.caption)
}
.help("Scan a Pokémon from Phone Mirroring")
.sheet(isPresented: $showingScanner) {
    ScannerSheet(bench: bench, store: store, addLeague: $addLeague)
}
```

New `@State` vars needed in `BenchView`: `showingScanner: Bool`, reuse existing `addLeague`.

After a successful scan-and-add, set `selectedID` to the new entry's id (same pattern as `addToBench(_:)`).

---

## Entitlement Change

In `PokeParty/PokeParty.entitlements`, add:

```xml
<key>com.apple.security.screen-recording</key>
<true/>
```

The system will show a one-time permission dialog the first time `SCShareableContent` is queried.

---

## Known Constraints

- **Window not found:** Phone Mirroring window may be minimized, behind other windows, or the app may not be running. Return a clear error: "Open iPhone Mirroring and navigate to a Pokémon's detail screen, then scan again."
- **OCR ambiguity:** Some species names OCR poorly (accents, special chars). The catch message ("This {name} was caught…") is the primary name source since it's plain text away from decorative UI, with the old largest-plausible-text heuristic as fallback; fuzzy matching covers the rest.
- **CP badge OCR is unreliable:** Pokémon GO's gold CP badge frequently fails to OCR (e.g. merges with the phone's clock digits). CP is now a best-effort bonus signal, not required.
- **The appraisal bars are the primary IV source, not text.** "X / X HP" OCRs reliably, but the *level* is not shown as text on the appraisal screen at all (the header's "Metang 55" is a nickname, not a level), so the HP-and-level route to the HP IV usually can't run: `floor(cpm(level) * (baseHp + hpIV)) == scannedMaxHP` needs a level. It still applies on screens where a level is visible, and stays in as a filter, but the bars are what actually pin down a spread.
- **Moves not scanned:** Moves section of the game UI is on the same detail screen but requires OCR of move names and fuzzy matching against `pokemon.fastMoves` / `pokemon.chargedMoves`. Deferred — user uses the existing move pickers in BenchDetailView.

---

## Out of Scope (Tier 2, separate branch)

- iOS broadcast extension (ReplayKit `RPBroadcastSampleHandler`)
- Move name OCR and matching
- Batch scanning (multiple Pokémon without re-tapping)

---

## Bar pixel analysis (added after Tier 1 feedback)

CP/HP-derived filtering alone left Attack/Defense IVs essentially unconstrained
(only HP could be pinned down via the CPM table), so IV accuracy was poor in
practice. Pokémon GO's detail screen actually shows Attack/Defense/HP as fill
bars where fill fraction = IV / 15 — reading them directly gives all three IVs
at once instead of a wide candidate list.

**What the screen actually looks like** (from `PokePartyTests/Fixtures/metang_appraisal.png`,
a real capture): the appraisal card is a small white panel low on the left of
the phone screen. Each stat is a label with a bar *below* it, sharing the
label's left edge. **A bar is three rounded segments of 5 IVs each**, separated
by narrow gaps of white card — so there is no single fill→track edge to find,
and any measurement that walks a contiguous run stops at the first gap. Filled
segments are saturated (orange/red, per stat); unfilled ones are a pale gray
(226,226,228) that is distinctly darker than the white card behind them.

**`ScreenScanner.extractBarIVs(from:image:)`** (`Services/ScreenScanner.swift`):
- Anchors on the OCR'd "Attack"/"Defense"/"HP" labels (exact-match, so the
  "129 / 129 HP" line doesn't collide).
- Locates each bar's row by search, not by a fixed offset: within the band
  below a label, the bar's own row has an order of magnitude more bar-colored
  pixels than anything else.
- Counts rather than measures edges: `IV = 15 * fill / (fill + track)`, with
  segment gaps classified as card and landing in neither bucket. Needs no
  knowledge of the bar's pixel width (which changes with the window size) and
  no calibration against a separately known IV.
- Stops at the end of the bar — the first stretch of card wider than
  `rowSpacing * 0.15` — which is what distinguishes the small inter-segment
  gaps from the empty card beyond the bar's right edge, and keeps the scan out
  of the saturated trainer artwork alongside the card. All tolerances are
  fractions of the label row spacing, so the reader is resolution-independent.
- Cross-checks the three rows against each other by re-measuring all of them
  against the median right edge, since the bars are all the same width.
- `PixelSampler` (private struct in the same file) draws the `CGImage` into
  an sRGB bitmap context once and indexes into the raw buffer for fast
  per-pixel reads. **Note:** the buffer is stored top-down, so no vertical
  flip — an earlier version flipped and read every bar from its mirror image
  elsewhere on screen, which is what made bar readings nonsense.

**`ScannerModel`** passes `barIVs` to `computeCandidates`, which filters combos
to within ±1 of each bar-derived IV on top of the HP+level and CP filters.
`pullDown()` stages the bar reading itself rather than the top candidate — the
candidate list is ordered by stat product, so its first entry within tolerance
usually isn't the spread the bars showed. The live panel leads with
"IVs from bars: 2 / 15 / 13" and falls back to the ranked guess only when the
bars can't be read.

**Verification:** `PokePartyTests/ScreenScannerTests.swift` has two layers. Real
capture: `Fixtures/metang_appraisal.png` (an actual iPhone Mirroring window)
must read 2/15/13, and its OCR must yield name "Metang" (from the catch
message — the header says "Metang 55", the player's nickname), HP 129, and no
level. Synthetic: screens drawn in the same layout at spreads awkward to
collect by hand — hundos, empty bars, equal attack/defense, fills landing
exactly on segment boundaries. Keep the real fixture: earlier versions of this
reader passed synthetic tests while returning nonsense on the actual screen.
