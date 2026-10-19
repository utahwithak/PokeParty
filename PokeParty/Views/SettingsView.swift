//
//  SettingsView.swift
//  PokeParty
//
//  Reached from the "Settings" row under Cups in the sidebar. Lets the user
//  bring back cups they've hidden, restore purchases, and report issues on
//  the project's GitHub repo.
//

import SwiftUI
import StoreKit

struct SettingsView: View {
    @Bindable var store: RankingsStore
    var hiddenCups: HiddenCupsStore

    @Environment(EntitlementStore.self) private var entitlements
    @State private var showingRestoreAlert = false
    @State private var restoreMessage = ""

    private static let issuesURL = URL(string: "https://github.com/utahwithak/PokeParty/issues/new")!

    private var hiddenCupFormats: [RankingFormat] {
        store.cupFormats.filter { hiddenCups.isHidden($0.id) }
    }

    var body: some View {
        Form {
            dataSection
            megaSection
            hiddenCupsSection
            purchasesSection
            feedbackSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .alert("Restore Purchases", isPresented: $showingRestoreAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage)
        }
    }

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await store.rebuildCache() }
            } label: {
                Label("Rebuild Data Cache", systemImage: "arrow.triangle.2.circlepath")
            }
        } header: {
            Text("PvPoke Data")
        } footer: {
            Text("Check for updated rankings, or rebuild the local cache from scratch.")
        }

        Section {
            Picker("Ranking Order", selection: $store.rankingSource) {
                Text("PvPoke").tag(RankingsStore.RankingSource.pvpoke)
                Text("PokeParty (Local)").tag(RankingsStore.RankingSource.local)
            }
            if case .building(let formatTitle) = store.localRankingBuilder.phase {
                HStack {
                    ProgressView(value: store.localRankingBuilder.progress)
                    Text(formatTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #if DEBUG && os(macOS)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.localRankingBuilder.cacheDirectory])
            } label: {
                Label("Reveal Local Rankings Cache", systemImage: "folder")
            }
            #endif
        } header: {
            Text("Ranking Order")
        } footer: {
            Text("PvPoke shows their published ranking order. PokeParty (Local) computes its own ordering on-device from the raw game data, using PokeParty's own battle engine — it won't exactly match PvPoke's list. Great/Ultra/Master League are kept up to date automatically in the background; cups compute the first time you view them in Local mode.")
        }
    }

    private var megaSection: some View {
        Section {
            Toggle("Show Mega Evolutions", isOn: $store.showMegaEvolutions)
        } footer: {
            Text("Include Mega Evolutions when picking Pokémon in the Team Builder, Bench, Rank Checker, Breakpoints, and 1v1 Simulator — even in leagues where Megas aren't officially legal.")
        }
    }

    private var hiddenCupsSection: some View {
        Section {
            if hiddenCupFormats.isEmpty {
                Text("No cups are hidden. Hide a cup from its context menu in the sidebar to move it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hiddenCupFormats) { format in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(format.title)
                            Text(format.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { hiddenCups.unhide(format.id) }
                    }
                }
            }
        } header: {
            Text("Hidden Cups")
        }
    }

    private var purchasesSection: some View {
        Section {
            if entitlements.isUnlocked {
                Label("PokeParty Pro — Unlocked", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task { await entitlements.purchase() }
                } label: {
                    HStack {
                        Label("Unlock PokeParty Pro", systemImage: "wand.and.stars")
                        Spacer()
                        if let price = entitlements.product?.displayPrice {
                            Text(price).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(entitlements.isPurchasing || entitlements.product == nil)
            }
            Button("Restore Purchases") { restorePurchases() }
        } footer: {
            Text(entitlements.isUnlocked
                ? "Unlocked: \(EntitlementStore.proFeatureList)."
                : "Unlock \(EntitlementStore.proFeatureList). Restore if you've purchased on another device.")
        }
    }

    private var feedbackSection: some View {
        Section {
            Link(destination: Self.issuesURL) {
                Label("Report an Issue on GitHub", systemImage: "ladybug")
            }
        } footer: {
            Text("PokeParty is open source. File a bug or feature request on GitHub.")
        }
    }

    private func restorePurchases() {
        Task { @MainActor in
            do {
                try await AppStore.sync()
                restoreMessage = "Your purchases have been restored."
            } catch {
                restoreMessage = "Couldn't restore purchases: \(error.localizedDescription)"
            }
            showingRestoreAlert = true
        }
    }
}
