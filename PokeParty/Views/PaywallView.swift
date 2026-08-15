//
//  PaywallView.swift
//  PokeParty
//
//  Shown in place of Party Finder (and as a prompt near scan buttons) when
//  the pro unlock hasn't been purchased. Reads EntitlementStore from the
//  environment so no extra parameter threading is needed.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(EntitlementStore.self) private var entitlements

    private let features: [(icon: String, text: String)] = [
        ("wand.and.stars",      "Party Finder — find the best team from your bench or the PvP meta"),
        ("brain",               "AI Optimizer — hill-climb movesets against the ranked field"),
        ("trophy.fill",         "Tournament Simulator — run round-robins and bracket events"),
        ("camera.viewfinder",   "Screen Scanner — read IVs from iPhone Mirroring automatically"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("PokeParty Pro")
                    .font(.title.weight(.bold))
                Text("Advanced tools for competitive PvP.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(features, id: \.icon) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.icon)
                            .frame(width: 22)
                            .foregroundStyle(.tint)
                        Text(feature.text)
                            .font(.subheadline)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 10) {
                Button {
                    Task { await entitlements.purchase() }
                } label: {
                    Group {
                        if entitlements.isPurchasing {
                            ProgressView().controlSize(.small)
                        } else if let price = entitlements.product?.displayPrice {
                            Text("Unlock  ·  \(price)")
                        } else {
                            Text("Unlock")
                        }
                    }
                    .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(entitlements.isPurchasing || entitlements.product == nil)

                Button("Restore Purchases") {
                    Task {
                        try? await AppStore.sync()
                        await entitlements.load()
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let error = entitlements.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer(minLength: 0)
        }
        .padding()
    }
}
