//
//  MatchupDetailComponents.swift
//  PokeParty
//
//  Row and card components for the matchup detail view.
//

import SwiftUI

struct ScenarioStripRow: View {
    let shieldsA: Int
    let shieldsB: Int
    let solution: ShieldSearch.Solution
    let log: BattleLog
    let selected: Bool
    let onSelect: () -> Void
    let isLast: Bool

    private var rating: Int { solution.ratingA }
    private var color: Color { rating > 500 ? Theme.win : rating < 500 ? Theme.loss : .secondary }
    private var icon: String { rating > 500 ? "circle" : rating < 500 ? "xmark" : "minus" }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    // Shield counts — blue for A, orange for B
                    HStack(spacing: 4) {
                        Label("\(shieldsA)", systemImage: "shield.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                        Text("/")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Label("\(shieldsB)", systemImage: "shield.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(width: 68)

                    // Win/loss icon + rating
                    HStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .bold))
                        Text("\(rating)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(color)
                    .frame(width: 44, alignment: .leading)

                    // Mini timeline strips: one lane per Pokémon
                    VStack(spacing: 3) {
                        MiniTimelineStrip(log: log, side: 0, color: .blue)
                        MiniTimelineStrip(log: log, side: 1, color: .orange)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isLast {
                Divider().padding(.leading, 10)
            }
        }
    }
}

// MARK: - Mini timeline strip (Canvas-drawn, one lane)

struct MiniTimelineStrip: View {
    let log: BattleLog
    let side: Int
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let maxTime = Double(max(log.frames.last?.timeMs ?? 1, 1))

            // Background track
            var track = Path()
            track.addRoundedRect(
                in: CGRect(x: 0, y: (size.height - 2) / 2, width: size.width, height: 2),
                cornerSize: .init(width: 1, height: 1))
            ctx.fill(track, with: .color(.primary.opacity(0.08)))

            for frame in log.frames {
                guard let event = frame.event, event.actor == side else { continue }
                let x = size.width * Double(frame.timeMs) / maxTime
                switch event.kind {
                case .charged:
                    var p = Path()
                    p.addRoundedRect(
                        in: CGRect(x: x - 3, y: 0, width: 6, height: size.height),
                        cornerSize: .init(width: 1.5, height: 1.5))
                    ctx.fill(p, with: .color(color))
                case .fast:
                    let h = size.height * 0.5
                    var p = Path()
                    p.addRect(CGRect(x: x - 1, y: (size.height - h) / 2, width: 2, height: h))
                    ctx.fill(p, with: .color(color.opacity(0.4)))
                case .faint:
                    let r: CGFloat = 4, cy = size.height / 2
                    var p = Path()
                    p.move(to: .init(x: x - r, y: cy - r)); p.addLine(to: .init(x: x + r, y: cy + r))
                    p.move(to: .init(x: x + r, y: cy - r)); p.addLine(to: .init(x: x - r, y: cy + r))
                    ctx.stroke(p, with: .color(Theme.loss), lineWidth: 1.5)
                default:
                    break
                }
            }
        }
        .frame(height: 16)
    }
}

// MARK: - Combatant card

struct MatchupMemberCard: View {
    let side: MatchupModel.Side
    let store: RankingsStore
    @Bindable var model: MatchupModel

    private var member: TeamMember? { model.member(for: side) }
    private var species: Pokemon? {
        member.flatMap { store.pokemonById[$0.speciesId] }
    }
    private var recommended: [String] {
        member.flatMap { store.entry(id: $0.speciesId)?.moveset } ?? []
    }
    /// Matches the timeline's lane colors (side A blue, side B orange).
    private var accent: Color { side == .a ? .blue : .orange }

    var body: some View {
        if let member, let species {
            VStack(alignment: .leading, spacing: 8) {
                header(member: member, species: species)
                TypeBadgeRow(types: species.displayTypes)
                Divider()
                movesetEditor(member: member, species: species)
                if species.isShadow || member.shadow {
                    shadowToggle(member: member)
                }
                Divider()
                ivsSection(member: member)
                Divider()
                shieldPicker
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        } else {
            emptySlot
        }
    }

    private func header(member: TeamMember, species: Pokemon) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                sideLabel
                HStack(spacing: 4) {
                    Text(species.speciesName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if member.shadow { ShadowBadge() }
                }
            }
            Spacer()
            Button {
                model.set(nil, side: side)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear this side")
        }
    }

    private var sideLabel: some View {
        HStack(spacing: 5) {
            Circle().fill(accent).frame(width: 8, height: 8)
            Text(side == .a ? "SIDE A" : "SIDE B")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    private func movesetEditor(member: TeamMember, species: Pokemon) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TeamMovePicker(
                label: "Fast",
                currentId: member.fastMoveId,
                optionIds: species.fastMoves,
                recommendedId: recommended.first,
                includesNone: false,
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setFastMove(id, side: side) } })
            TeamMovePicker(
                label: "Charged 1",
                currentId: member.chargedMoveIds.first ?? "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 1 ? recommended[1] : nil,
                includesNone: false,
                species: species,
                store: store,
                onSelect: { if let id = $0 { model.setChargedMove(id, slot: 0, side: side) } })
            TeamMovePicker(
                label: "Charged 2",
                currentId: member.chargedMoveIds.count > 1 ? member.chargedMoveIds[1] : "",
                optionIds: species.chargedMoves,
                recommendedId: recommended.count > 2 ? recommended[2] : nil,
                includesNone: true,
                species: species,
                store: store,
                onSelect: { model.setChargedMove($0, slot: 1, side: side) })
            if species.hasThirdChargedMove {
                TeamMovePicker(
                    label: "Charged 3",
                    currentId: member.chargedMoveIds.count > 2 ? member.chargedMoveIds[2] : "",
                    optionIds: species.extraChargedMoves ?? [],
                    recommendedId: recommended.count > 3 ? recommended[3] : nil,
                    includesNone: true,
                    species: species,
                    store: store,
                    onSelect: { model.setChargedMove($0, slot: 2, side: side) })
                MegaLevelPicker(level: member.megaLevel ?? species.megaLevel,
                                onSelect: { model.setMegaLevel($0, side: side) })
            }
        }
    }

    private func shadowToggle(member: TeamMember) -> some View {
        Toggle("Shadow", isOn: Binding(
            get: { member.shadow },
            set: { model.setShadow($0, side: side) }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
    }

    private func ivsSection(member: TeamMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Custom IVs", isOn: Binding(
                get: { member.ivs != nil },
                set: { on in
                    model.setIVs(on ? (member.ivs ?? IVs(atk: 15, def: 15, hp: 15)) : nil, side: side)
                }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)

            if let ivs = member.ivs {
                HStack(spacing: 6) {
                    ivField("ATK", ivs.atk) { model.setIVs(IVs(atk: $0, def: ivs.def, hp: ivs.hp), side: side) }
                    ivField("DEF", ivs.def) { model.setIVs(IVs(atk: ivs.atk, def: $0, hp: ivs.hp), side: side) }
                    ivField("HP",  ivs.hp)  { model.setIVs(IVs(atk: ivs.atk, def: ivs.def, hp: $0), side: side) }
                }
            } else {
                Text("Uses the best possible IV spread for this league's CP cap.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ivField(_ label: String, _ value: Int, onChange: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { value },
                set: { onChange(min(max($0, 0), 15)) }
            ), format: .number)
            .labelsHidden()
            .frame(width: 34)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
    }

    private var shieldPicker: some View {
        HStack(spacing: 6) {
            Text("Shields")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Picker("Shields", selection: side == .a ? $model.shieldsA : $model.shieldsB) {
                ForEach(0..<3, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var emptySlot: some View {
        VStack(spacing: 6) {
            sideLabel
            Image(systemName: "plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add from the list")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 150)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.quaternary)
        )
    }
}
