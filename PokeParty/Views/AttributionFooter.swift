//
//  AttributionFooter.swift
//  PokeParty
//
//  Required MIT attribution for PvPoke, linking out to the source website.
//

import SwiftUI

/// A footer crediting PvPoke. The rows leave the app and open PvPoke's website
/// and source repository in the system browser (satisfies PvPoke's MIT
/// attribution requirement).
struct AttributionFooter: View {
    var body: some View {
        Section {
            linkRow(
                title: "Data & rankings from PvPoke",
                subtitle: "pvpoke.com",
                url: URL(string: "https://pvpoke.com")!
            )
            linkRow(
                title: "Source on GitHub",
                subtitle: "github.com/pvpoke/pvpoke",
                url: URL(string: "https://github.com/pvpoke/pvpoke")!
            )
        } footer: {
            Text("PvPoke is open source under the MIT License. PokeParty is an unofficial app and is not affiliated with PvPoke or Niantic.")
        }
    }

    private func linkRow(title: String, subtitle: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    List {
        AttributionFooter()
    }
}
