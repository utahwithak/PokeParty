//
//  OpponentScanView.swift
//  PokeParty
//
//  iPhone "Screen Scan" tool: begin a scan, switch to Pokémon GO, and each
//  opponent in a battle is read off the screen — name, CP and type icons —
//  matched to a species, and handed to Opponent Check (and to a Mac running
//  Opponent Check, if one is on the network). Open a Pokémon's appraisal screen
//  and its IVs are read as well, shown here and posted as a notification.
//  A Pro feature — gated in ContentView.
//

#if os(iOS)

import SwiftUI

struct OpponentScanView: View {
    let store: RankingsStore
    let scan: OpponentScanModel
    let bench: BenchStore

    @State private var showDetails = false
    @State private var benchMessage: String?

    var body: some View {
        List {
            // The button gets its own section with no row chrome, so it reads as
            // a standalone action rather than a button inside a list cell; the
            // status lines sit underneath as the section's footer.
            Section {
                beginButton
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = scan.stream.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                    if scan.isScanning {
                        Label("Scanning — switch to Pokémon GO and start a battle.", systemImage: "dot.radiowaves.left.and.right")
                    }
                    if let mac = scan.link.macName {
                        Label("Sending to \(mac)", systemImage: "desktopcomputer")
                    }
                }
            }

            Section {
                DisclosureGroup("What does Screen Scan do?", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("While you battle in Pokémon GO, PokeParty reads your opponent's name, CP and type icons off the screen and works out which Pokémon it is — including regional forms like Alolan Ninetales. Opponents are added to Check Opponent so you can see how your team matches up.")
                        Text("It also reads IVs: open a Pokémon's appraisal screen (the Attack / Defense / HP bars) and its IVs, percentage and best league rank appear below and arrive as a notification, so you don't have to leave Pokémon GO.")
                        Text("Tap Begin Scan, choose “Entire Screen” in the system sheet, then open Pokémon GO. Frames are processed on this iPhone; nothing is recorded or saved, and a full-screen read only happens when the appraisal screen is showing.")
                        Text("If PokeParty is open on a Mac on the same Wi-Fi (Check Opponent), detections are also sent there. Requires iOS 27.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }
            }

            if !scan.ivScan.history.isEmpty {
                Section("IV results") {
                    ForEach(scan.ivScan.history) { entry in
                        ivRow(entry)
                            .swipeActions {
                                Button("Add to Bench") { addToBench(entry) }
                                    .tint(.accentColor)
                            }
                    }
                }
            }

            if !scan.detections.isEmpty {
                Section("Detected opponents") {
                    ForEach(scan.detections) { detection in
                        detectionRow(detection)
                    }
                }
            }

            #if DEBUG
            if scan.isScanning {
                Section("Debug") {
                    Text("OCR: " + (scan.stream.debugLines.isEmpty ? "—" : scan.stream.debugLines.joined(separator: " | ")))
                        .font(.caption2.monospaced())
                    Text("Header: " + (scan.stream.debugHeader.isEmpty ? "—" : scan.stream.debugHeader))
                        .font(.caption2.monospaced())
                    if let latest = scan.detections.first {
                        Text("Icons: " + latest.iconSummary)
                            .font(.caption2.monospaced())
                    }
                }
            }
            #endif
        }
        .navigationTitle("Screen Scan")
        .toolbar {
            if !scan.detections.isEmpty || !scan.ivScan.history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { scan.clear() }
                }
            }
        }
        .alert("My Bench", isPresented: Binding(
            get: { benchMessage != nil },
            set: { if !$0 { benchMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(benchMessage ?? "")
        }
    }

    private func ivRow(_ entry: ScanModel.HistoryEntry) -> some View {
        let ivs = entry.ivs
        let percent = Double(ivs.atk + ivs.def + ivs.hp) / 45 * 100
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.speciesName)
                    .font(.subheadline.weight(.medium))
                if let hit = entry.bestRank {
                    let evolved = hit.speciesName == entry.speciesName ? "" : " as \(hit.speciesName)"
                    Text("Best: #\(hit.rank) in \(hit.league.title) League\(evolved)")
                        .font(.caption)
                        .foregroundStyle(hit.rank <= ScanModel.goodRankThreshold ? Color.green : Color.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(ivs.atk) / \(ivs.def) / \(ivs.hp)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(String(format: "%.1f%%", percent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Adds a scanned Pokémon to My Bench in the league it ranks best in.
    private func addToBench(_ entry: ScanModel.HistoryEntry) {
        guard let speciesId = entry.speciesId else { return }
        if bench.duplicate(speciesId: speciesId, ivs: entry.ivs, capturedDate: entry.date, store: store) != nil {
            benchMessage = "\(entry.speciesName) with these IVs is already on your bench."
            return
        }
        let league = entry.bestRank.flatMap { League(rawValue: $0.league.cap) }
        _ = bench.addFromScan(
            speciesId: speciesId, ivs: entry.ivs, capturedDate: entry.date,
            shadow: store.pokemonById[speciesId]?.isShadow ?? false, league: league, store: store)
        benchMessage = "Added \(entry.speciesName) to My Bench."
    }

    private var beginButton: some View {
        Button {
            if scan.isScanning {
                Task { await scan.end() }
            } else {
                scan.begin(store: store)
            }
        } label: {
            // An HStack rather than a `Label`: inside a List, `Label` lays its
            // icon out in a fixed leading column, so the content never centres.
            HStack(spacing: 8) {
                Image(systemName: scan.isScanning ? "stop.circle.fill" : "viewfinder")
                Text(scan.isScanning ? "Stop Scan" : "Begin Scan")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(scan.isScanning ? .red : .accentColor)
        .controlSize(.large)
    }

    private func detectionRow(_ detection: OpponentDetection) -> some View {
        let matches = resolve(detection)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(matches.count == 1 ? matches[0].speciesName : detection.name)
                    .font(.subheadline.weight(.medium))
                if matches.count > 1 {
                    Text("Could be: " + matches.map(\.speciesName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if matches.isEmpty {
                    Text("Not matched to a ranked Pokémon in this format")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let cp = detection.cp {
                Text("CP \(cp)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The same name + type-icon resolution Check Opponent uses.
    private func resolve(_ detection: OpponentDetection) -> [Pokemon] {
        let ranked = store.entries.compactMap { store.pokemonById[$0.speciesId] }
        let byName = OpponentNameMatcher.candidates(for: detection.name, in: ranked)
        return OpponentNameMatcher.narrow(byName, byIcons: detection.icons)
    }
}

#endif
