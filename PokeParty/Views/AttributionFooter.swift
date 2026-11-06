//
//  AttributionFooter.swift
//  PokeParty
//
//  Required MIT attribution for PvPoke, linking out to the source website.
//

import SwiftUI

/// A footer crediting PvPoke. The links open PvPoke's website and source
/// repository in the system browser (satisfies PvPoke's MIT attribution
/// requirement). Each link is only as big as its own text and icon, so the
/// empty space beside it isn't clickable.
struct AttributionFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 28) {
                linkItem(
                    title: "Data & rankings from PvPoke",
                    subtitle: "pvpoke.com",
                    url: URL(string: "https://pvpoke.com")!
                )
                linkItem(
                    title: "Source on GitHub",
                    subtitle: "github.com/pvpoke/pvpoke",
                    url: URL(string: "https://github.com/pvpoke/pvpoke")!
                )
                Spacer(minLength: 0)
            }
            Text("PvPoke is open source under the MIT License. PokeParty is an unofficial fan-made tool. It is not affiliated with, endorsed by, or sponsored by PvPoke, Nintendo, Game Freak, The Pokémon Company, or Scopely. Pokémon and Pokémon GO are trademarks of their respective owners.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func linkItem(title: String, subtitle: String, url: URL) -> some View {
        Link(destination: url) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Without this the link stretches to fill the row on macOS.
        .fixedSize()
    }
}

#Preview {
    AttributionFooter()
        .padding()
}
