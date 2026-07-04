//
//  BattleTimelineView.swift
//  PokeParty
//
//  A scrubbable key-frame timeline for a single 1v1 battle (plan M7.2). Shows both
//  Pokémon's residuals (HP / energy / shields) at the selected frame, a strip of
//  event ticks you can tap or scrub through, and the current event description.
//  Reused by the 3v3 viewer (M7.5).
//

import SwiftUI

/// Display info for one side of a battle.
struct BattleParticipant: Hashable {
    let name: String
    let types: [String]
    var shadow: Bool = false
}

struct BattleTimelineView: View {
    let log: BattleLog
    let sideA: BattleParticipant
    let sideB: BattleParticipant
    /// Resolves a move id to its data (for names/types); defaults to unknown.
    var move: (String) -> Move? = { _ in nil }

    @State private var frameIndex = 0

    private var frames: [BattleFrame] { log.frames }
    private var current: BattleFrame? {
        frames.indices.contains(frameIndex) ? frames[frameIndex] : frames.last
    }
    private func maxHp(_ side: Int) -> Int { max(frames.first?.hp[side] ?? 1, 1) }
    private var maxShields: Int { max(frames.first?.shields.max() ?? 0, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let frame = current {
                resultHeader
                HStack(alignment: .top, spacing: 16) {
                    sidePanel(sideA, side: 0, frame: frame)
                    sidePanel(sideB, side: 1, frame: frame)
                }
                keyframeStrip
                scrubber
                eventRow(frame)
            } else {
                ContentUnavailableView("No timeline", systemImage: "clock")
            }
        }
        .onAppear { frameIndex = max(frames.count - 1, 0) }   // start on the outcome
    }

    // MARK: - Header

    private var resultHeader: some View {
        HStack {
            Text("Battle")
                .font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Text("\(log.ratingA)")
                    .foregroundStyle(log.ratingA >= log.ratingB ? Theme.win : Theme.loss)
                Text("–").foregroundStyle(.secondary)
                Text("\(log.ratingB)")
                    .foregroundStyle(log.ratingB > log.ratingA ? Theme.win : Theme.loss)
            }
            .font(.headline.monospacedDigit())
            .help("Final battle rating for each side (0–1000, 500 = even).")
        }
    }

    // MARK: - Side panel (residuals)

    private func sidePanel(_ p: BattleParticipant, side: Int, frame: BattleFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(p.name).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                if p.shadow { ShadowBadge() }
            }
            TypeBadgeRow(types: p.types)

            residualBar("HP", value: frame.hp[side], max: maxHp(side), color: .green,
                        text: "\(frame.hp[side])")
            residualBar("Energy", value: frame.energy[side], max: 100, color: .yellow,
                        text: "\(frame.energy[side])")
            shieldRow(frame.shields[side])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func residualBar(_ label: String, value: Int, max: Int, color: Color, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.caption.monospacedDigit())
            }
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(color)
                        .scaleEffect(x: max > 0 ? Double(value) / Double(max) : 0, y: 1, anchor: .leading)
                }
                .frame(height: 8)
        }
    }

    @ViewBuilder
    private func shieldRow(_ shields: Int) -> some View {
        if maxShields > 0 {
            HStack(spacing: 4) {
                Text("Shields").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(0..<maxShields, id: \.self) { i in
                    Image(systemName: i < shields ? "shield.fill" : "shield")
                        .font(.caption2)
                        .foregroundStyle(i < shields ? Color.blue : Color.secondary.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Key-frame strip

    private var keyframeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                        tick(frame, index: index)
                            .id(index)
                            .onTapGesture { frameIndex = index }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 40)
            .onChange(of: frameIndex) { _, new in
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func tick(_ frame: BattleFrame, index: Int) -> some View {
        let selected = index == frameIndex
        let kind = frame.event?.kind
        let height: CGFloat = kind == .charged ? 26 : (kind == .faint ? 30 : (kind == .fast ? 12 : 18))
        let color: Color = {
            switch kind {
            case .faint: return Theme.loss
            case nil: return .secondary
            default: return frame.event?.actor == 0 ? .blue : .orange
            }
        }()
        return RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(selected ? 1 : 0.55))
            .frame(width: kind == .charged ? 8 : 5, height: height)
            .overlay(alignment: .top) {
                if kind == .faint {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary, lineWidth: 1)
                }
            }
    }

    // MARK: - Scrubber + event text

    private var scrubber: some View {
        HStack(spacing: 10) {
            Button { frameIndex = Swift.max(frameIndex - 1, 0) } label: {
                Image(systemName: "chevron.left")
            }.disabled(frameIndex == 0)
            Slider(
                value: Binding(
                    get: { Double(frameIndex) },
                    set: { frameIndex = Int($0.rounded()) }),
                in: 0...Double(Swift.max(frames.count - 1, 1)))
            Button { frameIndex = Swift.min(frameIndex + 1, frames.count - 1) } label: {
                Image(systemName: "chevron.right")
            }.disabled(frameIndex >= frames.count - 1)
        }
        .buttonStyle(.borderless)
    }

    private func eventRow(_ frame: BattleFrame) -> some View {
        HStack {
            Text(eventText(frame.event)).font(.subheadline)
            Spacer()
            Text(String(format: "%.1fs", Double(frame.timeMs) / 1000))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func eventText(_ event: BattleEvent?) -> String {
        guard let event else { return "Battle start" }
        let who = event.actor == 0 ? sideA.name : sideB.name
        switch event.kind {
        case .fast:
            return "\(who) used \(moveName(event.moveId) ?? "fast move")"
        case .charged:
            let dmg = event.damage.map { " · \($0) dmg" } ?? ""
            let shield = event.shielded ? " (shielded)" : ""
            return "\(who) used \(moveName(event.moveId) ?? "charged move")\(dmg)\(shield)"
        case .faint:
            return "\(who) fainted"
        case .switchIn:
            return "\(who) switched in"
        case .timeout:
            return "Time expired"
        }
    }

    private func moveName(_ id: String?) -> String? {
        id.flatMap { move($0)?.name }
    }
}
