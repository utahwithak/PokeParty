//
//  RankCheckerInputView.swift
//  PokeParty
//
//  Middle column for the Rank Checker: IV entry + Pokémon search/selection.
//

import SwiftUI

struct RankCheckerInputView: View {
    var store: RankingsStore
    @Bindable var model: RankCheckerModel

    private var results: [Pokemon] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.allPokemon }
        return store.allPokemon.filter { $0.speciesName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(selection: $model.selectedSpeciesId) {
            Section("IVs (0–15)") {
                HStack(spacing: 12) {
                    IVField(label: "ATK", value: $model.atk, color: Theme.attack)
                    IVField(label: "DEF", value: $model.def, color: Theme.defense)
                    IVField(label: "HP", value: $model.hp, color: Theme.hp)
                }
                .padding(.vertical, 2)
            }

            Section("Level Cap") {
                // Menu style, not segmented: segmented pickers inside a macOS
                // List emit AttributeGraph cycles on re-layout.
                Picker("Level Cap", selection: $model.levelCap) {
                    Text("40").tag(40.0)
                    Text("41").tag(41.0)
                    Text("50").tag(50.0)
                    Text("51 · Best Buddy").tag(51.0)
                }
                .labelsHidden()
            }

            Section("Pokémon") {
                ForEach(results) { pokemon in
                    HStack(spacing: 10) {
                        Text(pokemon.speciesName)
                            .font(.body.weight(.medium))
                        Spacer()
                        TypeBadgeRow(types: pokemon.displayTypes)
                    }
                    .tag(pokemon.speciesId)
                }
            }
        }
        .navigationTitle("Rank Checker")
        .inlineNavigationTitle()
        .searchable(text: $model.searchText, prompt: "Search Pokémon")
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

/// A labeled IV entry with a text field and +/- buttons, clamped to 0–15.
/// (Buttons rather than a Stepper: Steppers in macOS Lists trigger
/// AttributeGraph-cycle warnings.)
private struct IVField: View {
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
