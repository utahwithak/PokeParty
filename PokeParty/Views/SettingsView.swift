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
    var store: RankingsStore
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
                ? "Party Finder, AI Optimizer, Tournament Simulator, and Screen Scanner are unlocked."
                : "Unlock Party Finder, AI Optimizer, Tournament Simulator, and Screen Scanner. Restore if you've purchased on another device.")
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
