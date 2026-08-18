//
//  ScanView.swift
//  PokeParty
//
//  The Scan tool: content column shows the live capture status (species,
//  CP/level, bar-read IVs) from the iPhone Mirroring window; the detail
//  column shows the multi-league IV grid for whatever's currently on screen
//  — tapping a league's rank cell stages that Pokémon for the bench in a
//  panel below the grid, where IVs can be corrected before confirming.
//
//  Backed by ScanModel/ScreenScanner, both macOS-only.
//

#if os(macOS)

import SwiftUI

// MARK: - Content column (live status)

struct ScanLiveView: View {
    let store: RankingsStore
    @Bindable var model: ScanModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusRow
                liveContent
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Scan")
        .onAppear { model.startScanning(store: store) }
        .onDisappear { model.stopScanning() }
    }

    private var statusRow: some View {
        HStack {
            Label("Live Scan", systemImage: "camera.viewfinder")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            liveIndicator
        }
    }

    @ViewBuilder
    private var liveIndicator: some View {
        switch model.liveStatus {
        case .scanning:
            ProgressView().controlSize(.small)
        default:
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.green)
                Text("Live").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        switch model.liveStatus {
        case .idle, .scanning:
            Text("Open iPhone Mirroring and show a Pokémon's detail or appraisal screen…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Retry") { model.startScanning(store: store) }
                    .buttonStyle(.bordered)
            }
        case .found(let live):
            foundContent(live)
        }
    }

    private func foundContent(_ live: ScanModel.LiveScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.rawName).font(.title3.weight(.medium))
                    let detail = detailLine(live)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                if let id = live.speciesId, let name = store.pokemonById[id]?.speciesName {
                    Label(name, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Label("No match", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let bars = barsLine(live.barIVs) {
                Text("IVs from bars: \(bars)")
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            } else if let top = live.candidates.first {
                Text("Best guess (bars unreadable): \(top.ivs.atk)/\(top.ivs.def)/\(top.ivs.hp)  ·  \(String(format: "%.1f%%", top.percent))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if live.speciesId != nil {
                Text("No IV candidates match yet — try the appraisal screen for bar readings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let level = model.determinedLevel(store: store) {
                Text("Detected: Lv \(level.formatted())")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }

            Text("Tap a rank in the grid to stage this Pokémon for your bench.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Only shown when all three bars were measured — a partial reading isn't
    /// something the user can act on.
    private func barsLine(_ barIVs: BarIVs?) -> String? {
        guard let atk = barIVs?.atk, let def = barIVs?.def, let hp = barIVs?.hp else { return nil }
        return "\(atk) / \(def) / \(hp)"
    }

    private func detailLine(_ live: ScanModel.LiveScan) -> String {
        var parts: [String] = []
        if let hp = live.maxHP { parts.append("\(hp) HP") }
        if let level = live.level { parts.append("Lvl \(String(format: "%.1f", level))") }
        if let cp = live.cp { parts.append("CP \(cp)") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Detail column (IV grid + staging)

struct ScanGridView: View {
    let store: RankingsStore
    let bench: BenchStore
    @Bindable var model: ScanModel
    /// Called after a staged pick is confirmed into the bench.
    var onAdded: ((BenchEntry.ID) -> Void)? = nil

    private var family: [Pokemon] {
        guard let id = model.currentSpeciesId else { return [] }
        return store.family(for: id)
    }

    private var selectedCell: (speciesId: String, league: CheckLeague)? {
        guard let staged = model.staged, let league = CheckLeague(rawValue: staged.league.rawValue) else { return nil }
        return (staged.speciesId, league)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if family.isEmpty {
                    ContentUnavailableView(
                        "No Pokémon Detected",
                        systemImage: "camera.viewfinder",
                        description: Text("Show a Pokémon in iPhone Mirroring, then wait for the next scan.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    IVLeagueGridView(
                        family: family,
                        ivs: model.currentIVs,
                        currentLevel: model.determinedLevel(store: store),
                        selected: selectedCell,
                        onSelect: { pokemon, league in
                            model.stage(pokemon: pokemon, league: league)
                        })
                    Text("Optimal rank = best level under the CP cap. Now = CP at the detected level with these IVs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider()
                stagingPanel
            }
            .padding(20)
        }
        .navigationTitle("Stage for Bench")
    }

    // MARK: - Staging panel

    @ViewBuilder
    private var stagingPanel: some View {
        if let staged = model.staged {
            VStack(alignment: .leading, spacing: 14) {
                Text("Staged for Bench").font(.headline)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(staged.speciesName).font(.body.weight(.medium))
                            .lineLimit(1)
                        Text("\(staged.league.title) League · captured \(staged.capturedDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear", role: .cancel) { model.clearStaged() }
                        .buttonStyle(.borderless)
                }

                HStack(spacing: 16) {
                    IVStageField(label: "ATK", value: ivBinding(\.atk), color: Theme.attack)
                    IVStageField(label: "DEF", value: ivBinding(\.def), color: Theme.defense)
                    IVStageField(label: "HP",  value: ivBinding(\.hp),  color: Theme.hp)
                }
                Text("Adjust if the scan misread these before adding.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let duplicate = model.duplicateWarning {
                    duplicateWarningBanner(duplicate)
                }

                Button {
                    if let id = model.confirmStaged(bench: bench, store: store) {
                        onAdded?(id)
                    }
                } label: {
                    Label("Add to Bench", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text("Tap a rank in the grid above to stage a Pokémon for your bench.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func duplicateWarningBanner(_ duplicate: BenchEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Looks like you already have this one — \(duplicate.nickname.isEmpty ? (store.pokemonById[duplicate.speciesId]?.speciesName ?? duplicate.speciesId) : duplicate.nickname), same IVs, caught \(duplicate.capturedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "that day").",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            Button("Add Anyway") {
                if let id = model.confirmStaged(bench: bench, store: store, force: true) {
                    onAdded?(id)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ivBinding(_ keyPath: WritableKeyPath<IVs, Int>) -> Binding<Int> {
        Binding(
            get: { model.staged?.ivs[keyPath: keyPath] ?? 15 },
            set: { model.staged?.ivs[keyPath: keyPath] = min(max($0, 0), 15) }
        )
    }
}

// MARK: - IV field

private struct IVStageField: View {
    let label: String
    @Binding var value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            HStack(spacing: 4) {
                TextField(label, value: $value, format: .number)
                    .labelsHidden()
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                Button("−") { value = max(value - 1, 0) }
                    .buttonStyle(.bordered)
                Button("+") { value = min(value + 1, 15) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

#endif
