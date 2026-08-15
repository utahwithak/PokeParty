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

    @State private var showingRestoreAlert = false
    @State private var restoreMessage = ""

    private static let issuesURL = URL(string: "https://github.com/utahwithak/PokeParty/issues/new")!

    private var hiddenCupFormats: [RankingFormat] {
        store.cupFormats.filter { hiddenCups.isHidden($0.id) }
    }

    var body: some View {
        Form {
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
            Button("Restore Purchases") { restorePurchases() }
        } footer: {
            Text("Restore purchases you've made on another device.")
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
