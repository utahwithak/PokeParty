//
//  CaughtScanSheet.swift
//  PokeParty
//
//  Sheet for quickly judging a freshly caught Pokémon. Continuously scans
//  the iPhone Mirroring window for an appraisal screen, reads the bar IVs,
//  and shows GL / UL / ML ranks for the whole evolution family — no bench
//  staging, just a fast read-only result.
//
//  Backed by CaughtScanModel and ScreenScanner, both macOS-only.
//

#if os(macOS)

import SwiftUI

struct CaughtScanSheet: View {
    let store: RankingsStore

    @State private var model = CaughtScanModel()
    @Environment(\.dismiss) private var dismiss

    private let leagues: [CheckLeague] = [.great, .ultra, .master]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                livePanel
                Divider()
                if model.speciesId != nil {
                    rankSection
                } else {
                    noSpeciesPlaceholder
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 620)
        .onAppear  { model.startScanning(store: store) }
        .onDisappear { model.stopScanning() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Scan Caught")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Done") {
                model.stopScanning()
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
            Divider()
            ivControls
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
            Text("Open iPhone Mirroring and show a Pokémon's appraisal screen…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        case .error(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        case .found(let live):
            liveFoundContent(live)
        }
    }

    private func liveFoundContent(_ live: CaughtScanModel.LiveScan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.rawName).font(.body.weight(.medium))
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
            if live.fromBars {
                Text("IVs read from bars")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Bars unreadable — adjust IVs manually below")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Determined level + CP for the scanned species at that level.
            if let level = determinedLevel,
               let sid = model.speciesId,
               let species = store.pokemonById[sid],
               let cp = currentCP(for: species, at: level) {
                Text("Detected: Lv \(level.formatted()) · CP \(cp)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
        }
    }

    private func detailLine(_ live: CaughtScanModel.LiveScan) -> String {
        var parts: [String] = []
        if let cp = live.cp { parts.append("CP \(cp)") }
        if let level = live.level { parts.append("Lvl \(String(format: "%.1f", level))") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - IV controls

    private var ivControls: some View {
        HStack(spacing: 16) {
            IVScanField(label: "ATK", value: ivBinding(\.atk), color: Theme.attack)
            IVScanField(label: "DEF", value: ivBinding(\.def), color: Theme.defense)
            IVScanField(label: "HP",  value: ivBinding(\.hp),  color: Theme.hp)
        }
    }

    private func ivBinding(_ keyPath: WritableKeyPath<IVs, Int>) -> Binding<Int> {
        Binding(
            get: { model.ivs[keyPath: keyPath] },
            set: { model.ivs[keyPath: keyPath] = min(max($0, 0), 15) }
        )
    }

    // MARK: - Level / CP helpers

    /// Infers the current level from the scanned maxHP and known IVs.
    ///
    /// HP = floor(cpm × (baseHp + hpIV)) is an exact formula, so iterating
    /// the CPM table gives an exact level match. When multiple CPM indices
    /// yield the same integer HP (rare for most species), the one closest
    /// to the OCR-scanned level is preferred. Falls back to the OCR level
    /// when maxHP wasn't read.
    private var determinedLevel: Double? {
        guard let sid = model.speciesId,
              let species = store.pokemonById[sid] else { return nil }

        var scannedLevel: Double?
        var maxHP: Int?
        if case .found(let live) = model.liveStatus {
            scannedLevel = live.level
            maxHP = live.maxHP
        }

        if let maxHP {
            let baseHpPlusIV = Double(species.baseStats.hp + model.ivs.hp)
            var matches: [Double] = []
            for (index, cpm) in IVCalculator.cpms.enumerated() {
                if Int((cpm * baseHpPlusIV).rounded(.down)) == maxHP {
                    matches.append(1.0 + Double(index) * 0.5)
                }
            }
            if !matches.isEmpty {
                if let sl = scannedLevel {
                    return matches.min(by: { abs($0 - sl) < abs($1 - sl) })
                }
                return matches.first
            }
        }

        return scannedLevel
    }

    /// CP for a given Pokémon at a specific level with the current IVs.
    private func currentCP(for pokemon: Pokemon, at level: Double) -> Int? {
        guard let cpm = IVCalculator.cpm(forLevel: level) else { return nil }
        return IVCalculator.cp(
            baseAtk: pokemon.baseStats.atk,
            baseDef: pokemon.baseStats.def,
            baseHp:  pokemon.baseStats.hp,
            ivs: model.ivs,
            cpm: cpm
        )
    }

    // MARK: - Rank section

    private var family: [Pokemon] {
        guard let id = model.speciesId else { return [] }
        return store.family(for: id)
    }

    private var rankSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ivChip("ATK", model.ivs.atk, Theme.attack)
                ivChip("DEF", model.ivs.def, Theme.defense)
                ivChip("HP",  model.ivs.hp,  Theme.hp)
                Spacer()
                if let level = determinedLevel {
                    Text("at Lv \(level.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Pokémon")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 160, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    ForEach(leagues, id: \.self) { league in
                        Text(league.short)
                            .font(.caption.weight(.bold))
                            .frame(width: 90)
                            .gridColumnAlignment(.center)
                    }
                }
                Divider()
                ForEach(family) { pokemon in
                    GridRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pokemon.speciesName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            TypeBadgeRow(types: pokemon.displayTypes)
                        }
                        .frame(width: 160, alignment: .leading)

                        ForEach(leagues, id: \.self) { league in
                            rankCell(for: pokemon, league: league)
                                .frame(width: 90)
                        }
                    }
                    if pokemon.id != family.last?.id { Divider() }
                }
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Text("Optimal rank = best level under the CP cap. Now = CP at detected level with these IVs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func ivChip(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.85))
            Text("\(value)").font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color, in: Capsule())
    }

    @ViewBuilder
    private func rankCell(for pokemon: Pokemon, league: CheckLeague) -> some View {
        let nowCP = determinedLevel.flatMap { currentCP(for: pokemon, at: $0) }
        let nowFits = nowCP.map { $0 <= league.cap }

        VStack(spacing: 2) {
            if let result = IVCalculator.rank(
                baseAtk: pokemon.baseStats.atk,
                baseDef: pokemon.baseStats.def,
                baseHp:  pokemon.baseStats.hp,
                cpCap:   league.cap,
                ivs:     model.ivs
            ) {
                Text("#" + result.rank.formatted(.number.grouping(.never)))
                    .font(.callout.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                Text(String(format: "%.1f%%", result.percent))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(percentColor(result.percent))
                Text("L\(result.combo.level.formatted()) · \(result.combo.cp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            // Current-level eligibility badge — shows whether this form fits
            // under the cap right now without any powering up.
            if let cp = nowCP, let fits = nowFits {
                HStack(spacing: 2) {
                    Image(systemName: fits ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(fits ? Color.green : Color.red)
                    Text("now \(cp)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(fits ? Color.gray : Color.red)
                }
                .help(fits
                    ? "Eligible for \(league.title) League now (CP \(cp) ≤ \(league.cap))"
                    : "Over \(league.title) League cap now (CP \(cp) > \(league.cap))"
                )
            }
        }
    }

    private func percentColor(_ percent: Double) -> Color {
        switch percent {
        case 99...: Theme.win
        case 97..<99: .teal
        case 95..<97: .orange
        default: .secondary
        }
    }

    // MARK: - Placeholder

    private var noSpeciesPlaceholder: some View {
        ContentUnavailableView(
            "No Pokémon Detected",
            systemImage: "camera.viewfinder",
            description: Text("Show the appraisal screen in iPhone Mirroring, then wait for the next scan.")
        )
    }
}

// MARK: - IV field

private struct IVScanField: View {
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
