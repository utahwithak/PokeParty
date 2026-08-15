//
//  ScannerSheet.swift
//  PokeParty
//
//  Sheet presented from the Bench view's toolbar. Continuously captures the
//  iPhone Mirroring window and OCRs it into a "Live Scan" panel; the user
//  pulls a snapshot down into an editable "Add to Bench" panel — picking the
//  species, adjusting IVs, and correcting CP if needed — without interrupting
//  the live loop, so they can keep adding Pokémon back-to-back.
//
//  Backed by ScannerModel/ScreenScanner, which capture the iPhone Mirroring
//  window and are macOS-only, so this whole file is unavailable on iOS.
//

#if os(macOS)

import SwiftUI

struct ScannerSheet: View {
    let bench: BenchStore
    let store: RankingsStore
    var onAdded: ((BenchEntry.ID) -> Void)? = nil

    @State private var model = ScannerModel()
    @State private var speciesSearchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                livePanel
                pullDownButton
                Divider()
                stagedPanel
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 640)
        .onAppear { model.startLiveScanning(store: store) }
        .onDisappear { model.stopLiveScanning() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Scan Pokémon")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Done") {
                model.stopLiveScanning()
                dismiss()
            }
        }
    }

    // MARK: - Live panel

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live Scan", systemImage: "camera.viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                liveIndicator
            }
            liveContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
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
            HStack {
                Spacer()
                Text("Open iPhone Mirroring and show a Pokémon's detail screen…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(.vertical, 12)
        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    model.startLiveScanning(store: store)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        case .found(let live):
            liveFoundContent(live)
        }
    }

    private func liveFoundContent(_ live: ScannerModel.LiveScan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.rawName).font(.body.weight(.medium))
                    let detail = liveDetailLine(live)
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

            // The bars are a direct measurement, so they lead; the ranked
            // candidate is only a fallback for when they can't be read.
            if let bars = barsLine(live.barIVs) {
                Text("IVs from bars: \(bars)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            } else if let top = live.candidates.first {
                Text("Best guess (bars unreadable): \(top.ivs.atk)/\(top.ivs.def)/\(top.ivs.hp)  ·  \(String(format: "%.1f%%", top.percent))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if live.speciesId != nil {
                Text("No IV candidates match yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Only shown when all three bars were measured — a partial reading isn't
    /// something the user can act on.
    private func barsLine(_ barIVs: BarIVs?) -> String? {
        guard let atk = barIVs?.atk, let def = barIVs?.def, let hp = barIVs?.hp else { return nil }
        return "\(atk) / \(def) / \(hp)"
    }

    private func liveDetailLine(_ live: ScannerModel.LiveScan) -> String {
        var parts: [String] = []
        if let hp = live.maxHP { parts.append("\(hp) HP") }
        if let level = live.level { parts.append("Lvl \(String(format: "%.1f", level))") }
        if let cp = live.cp { parts.append("CP \(cp)") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Pull-down button

    private var pullDownButton: some View {
        HStack {
            Spacer()
            Button {
                model.pullDown()
            } label: {
                Label("Use This", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPullDown)
            Spacer()
        }
    }

    private var canPullDown: Bool {
        if case .found(let live) = model.liveStatus, live.speciesId != nil { return true }
        return false
    }

    // MARK: - Staged panel

    private var stagedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Bench").font(.headline)

            speciesPickerSection
            leagueSection
            ivSection
            cpSection

            Button {
                if let id = model.addStagedToBench(bench: bench, store: store) {
                    onAdded?(id)
                }
            } label: {
                Label("Add to Bench", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.staged.speciesId == nil)
        }
    }

    private var speciesPickerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pokémon").font(.subheadline.weight(.medium))
            if let id = model.staged.speciesId, let name = store.pokemonById[id]?.speciesName {
                HStack {
                    Text(name).font(.body.weight(.medium))
                    Spacer()
                    Button("Change") {
                        speciesSearchText = ""
                        model.staged.speciesId = nil
                    }
                    .font(.caption)
                }
            } else {
                TextField("Search species…", text: $speciesSearchText)
                    .textFieldStyle(.roundedBorder)
                if !speciesSearchText.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matchingSpecies) { pokemon in
                                Button {
                                    model.staged.speciesId = pokemon.speciesId
                                    speciesSearchText = ""
                                } label: {
                                    HStack {
                                        Text(pokemon.speciesName)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                if pokemon.id != matchingSpecies.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var matchingSpecies: [Pokemon] {
        Array(store.allPokemon.filter {
            $0.speciesName.localizedCaseInsensitiveContains(speciesSearchText)
        }.prefix(30))
    }

    private var leagueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("League").font(.subheadline.weight(.medium))
            Picker("League", selection: $model.selectedLeague) {
                ForEach(League.allCases) { l in Text(l.title).tag(l) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.selectedLeague) { _, _ in
                model.recomputeLiveCandidates(store: store)
            }
        }
    }

    private var ivSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IVs (0–15)").font(.subheadline.weight(.medium))
            HStack(spacing: 12) {
                IVEditField(label: "ATK", value: ivBinding(\.atk), color: Theme.attack)
                IVEditField(label: "DEF", value: ivBinding(\.def), color: Theme.defense)
                IVEditField(label: "HP",  value: ivBinding(\.hp),  color: Theme.hp)
            }

            if !model.staged.candidates.isEmpty {
                Text("Candidates from this scan").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.staged.candidates) { candidate in
                            candidateRow(candidate)
                            if candidate.id != model.staged.candidates.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 140)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func ivBinding(_ keyPath: WritableKeyPath<IVs, Int>) -> Binding<Int> {
        Binding(
            get: { model.staged.ivs[keyPath: keyPath] },
            set: { model.staged.ivs[keyPath: keyPath] = min(max($0, 0), 15) }
        )
    }

    private func candidateRow(_ candidate: ScannerModel.IVCandidate) -> some View {
        let selected = candidate.ivs == model.staged.ivs
        return Button {
            model.staged.ivs = candidate.ivs
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text("Rank \(candidate.rank)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Text("\(candidate.ivs.atk)/\(candidate.ivs.def)/\(candidate.ivs.hp)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 52, alignment: .leading)
                Text("Lv \(String(format: "%.1f", candidate.level))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)
                Spacer()
                Text(String(format: "%.1f%%", candidate.percent))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(rankColor(candidate.percent))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CP").font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                TextField("CP", text: cpText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .monospacedDigit()
                if let level = model.stagedDerivedLevel(store: store) {
                    Text("≈ Level \(String(format: "%.1f", level))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enter the CP shown on screen to estimate level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cpText: Binding<String> {
        Binding(
            get: { model.staged.cp.map(String.init) ?? "" },
            set: { model.staged.cp = Int($0) }
        )
    }

    // MARK: - Helpers

    private func rankColor(_ percent: Double) -> Color {
        switch percent {
        case 99...: .green
        case 95..<99: .blue
        case 90..<95: .orange
        default: .secondary
        }
    }
}

/// A labeled IV entry with a text field and +/- buttons, clamped to 0–15.
private struct IVEditField: View {
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
