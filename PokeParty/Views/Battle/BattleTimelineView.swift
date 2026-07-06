//
//  BattleTimelineView.swift
//  PokeParty
//
//  A scrubbable key-frame timeline for a single 1v1 battle (plan M7.2). Two lanes,
//  one per Pokémon, share a column axis: events on the same turn occupy the same
//  column so simultaneous moves line up vertically. Each column shows both sides'
//  residuals (HP / energy / shields) at that point. Reused by the 3v3 viewer (M7.5).
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
    /// Optional win/loss breakdown across all shield scenarios (M8.2), shown under
    /// the header when provided.
    var scenario: ShieldSearch.Solution?

    @State private var columnIndex = 0

    private var frames: [BattleFrame] { log.frames }

    /// Frame indices grouped into columns. Consecutive frames from the same turn
    /// share a column (so both Pokémon's simultaneous actions align); the initial
    /// event-less frame is always its own column.
    private var columns: [[Int]] {
        var cols: [[Int]] = []
        for i in frames.indices {
            if let lastIdx = cols.last?.last {
                let prev = frames[lastIdx], cur = frames[i]
                if prev.event != nil, cur.event != nil, prev.turn == cur.turn {
                    cols[cols.count - 1].append(i)
                    continue
                }
            }
            cols.append([i])
        }
        return cols
    }

    /// The residual snapshot for a column is its last frame (end-of-turn state).
    private func frame(forColumn c: Int) -> BattleFrame? {
        guard columns.indices.contains(c), let last = columns[c].last else { return frames.last }
        return frames[last]
    }
    private var current: BattleFrame? { frame(forColumn: columnIndex) }

    private func maxHp(_ side: Int) -> Int { max(frames.first?.hp[side] ?? 1, 1) }
    private var maxShields: Int { max(frames.first?.shields.max() ?? 0, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let frame = current {
                resultHeader
                if let scenario { scenarioRow(scenario) }
                HStack(alignment: .top, spacing: 16) {
                    sidePanel(sideA, side: 0, frame: frame)
                    sidePanel(sideB, side: 1, frame: frame)
                }
                keyframeStrip
                scrubber
                eventRow
            } else {
                ContentUnavailableView("No timeline", systemImage: "clock")
            }
        }
        .onAppear { columnIndex = max(columns.count - 1, 0) }   // start on the outcome
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

    /// Win/loss breakdown across every shield-timing scenario for both sides.
    private func scenarioRow(_ s: ShieldSearch.Solution) -> some View {
        let ties = s.scenarioTies > 0 ? " · \(s.scenarioTies)T" : ""
        return HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(s.scenarioWins >= s.scenarioLosses ? Theme.win : Theme.loss)
            Text("\(s.scenarioWins)W · \(s.scenarioLosses)L\(ties)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(s.scenarioWins >= s.scenarioLosses ? Theme.win : Theme.loss)
            Text("of \(s.scenarioCount) shield scenarios")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("best \(s.bestCaseA) · worst \(s.worstCaseA)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .help("Across every shield-timing choice for both sides: scenarios you win vs lose, and your best/worst-case rating.")
    }

    // MARK: - Side panel (residuals)

    private func sidePanel(_ p: BattleParticipant, side: Int, frame: BattleFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(laneColor(side)).frame(width: 8, height: 8)
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

    // MARK: - Key-frame strip (one lane per Pokémon, columns = turns)

    private let colWidth: CGFloat = 13
    private let laneHeight: CGFloat = 30
    private func laneColor(_ side: Int) -> Color { side == 0 ? .blue : .orange }

    private var keyframeStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            // Fixed labels so both lanes' timelines stay aligned while scrolling.
            VStack(spacing: 6) {
                laneLabel(sideA, side: 0)
                laneLabel(sideB, side: 1)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 6) {
                        laneRow(side: 0)
                        laneRow(side: 1)
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: columnIndex) { _, new in
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo("0-\(new)", anchor: .center) }
                }
            }
        }
    }

    private func laneLabel(_ p: BattleParticipant, side: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(laneColor(side)).frame(width: 8, height: 8)
            Text(p.name).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 96, height: laneHeight, alignment: .leading)
    }

    private func laneRow(side: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(columns.enumerated()), id: \.offset) { colIndex, col in
                laneCell(side: side, col: col, colIndex: colIndex)
                    .id("\(side)-\(colIndex)")
                    .onTapGesture { columnIndex = colIndex }
            }
        }
    }

    /// One column cell in a lane: the events this side performed on that turn
    /// (usually one), or an empty slot — so both lanes align by turn.
    private func laneCell(side: Int, col: [Int], colIndex: Int) -> some View {
        let selected = colIndex == columnIndex
        let events = col.compactMap { frames[$0].event }.filter { $0.actor == side }
        let isStart = col.count == 1 && frames[col[0]].event == nil
        return ZStack(alignment: .bottom) {
            if selected {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.12))
            }
            if isStart {
                Circle().fill(Color.secondary.opacity(0.45)).frame(width: 4, height: 4).padding(.bottom, 4)
            } else if !events.isEmpty {
                HStack(spacing: 1) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        tickShape(kind: e.kind, side: side)
                    }
                }
            }
        }
        .frame(width: colWidth, height: laneHeight, alignment: .bottom)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func tickShape(kind: BattleEventKind, side: Int) -> some View {
        let color = laneColor(side)
        switch kind {
        case .charged:
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 24)
        case .fast:
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.65)).frame(width: 5, height: 11)
        case .faint:
            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.loss)
        case .switchIn:
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 11)).foregroundStyle(color)
        case .timeout:
            EmptyView()
        }
    }

    // MARK: - Scrubber + event text

    private var scrubber: some View {
        HStack(spacing: 10) {
            Button { columnIndex = Swift.max(columnIndex - 1, 0) } label: {
                Image(systemName: "chevron.left")
            }.disabled(columnIndex == 0)
            Slider(
                value: Binding(
                    get: { Double(columnIndex) },
                    set: { columnIndex = Int($0.rounded()) }),
                in: 0...Double(Swift.max(columns.count - 1, 1)))
            Button { columnIndex = Swift.min(columnIndex + 1, columns.count - 1) } label: {
                Image(systemName: "chevron.right")
            }.disabled(columnIndex >= columns.count - 1)
        }
        .buttonStyle(.borderless)
    }

    private var eventRow: some View {
        let col = columns.indices.contains(columnIndex) ? columns[columnIndex] : []
        let events = col.compactMap { frames[$0].event }
        return HStack(alignment: .firstTextBaseline) {
            Text(events.isEmpty ? "Battle start" : events.map(eventText).joined(separator: "   ·   "))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let frame = current {
                Text(String(format: "%.1fs", Double(frame.timeMs) / 1000))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func eventText(_ event: BattleEvent) -> String {
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

#Preview {
    func f(_ turn: Int, _ ms: Int, _ hp: [Int], _ e: [Int], _ s: [Int], _ ev: BattleEvent?) -> BattleFrame {
        BattleFrame(turn: turn, timeMs: ms, hp: hp, energy: e, shields: s, buffs: [[0, 0], [0, 0]], event: ev)
    }
    func ev(_ actor: Int, _ kind: BattleEventKind, _ dmg: Int? = nil, shielded: Bool = false) -> BattleEvent {
        BattleEvent(actor: actor, kind: kind, moveId: nil, damage: dmg, shielded: shielded)
    }
    // Turns 2 and 3 each have BOTH mons throwing a fast move — they should stack in
    // one column, not offset.
    let frames: [BattleFrame] = [
        f(1, 0, [100, 100], [0, 0], [1, 1], nil),
        f(2, 500, [100, 97], [8, 0], [1, 1], ev(0, .fast, 3)),
        f(2, 500, [96, 97], [8, 7], [1, 1], ev(1, .fast, 4)),
        f(3, 1000, [96, 94], [16, 7], [1, 1], ev(0, .fast, 3)),
        f(3, 1000, [92, 94], [16, 14], [1, 1], ev(1, .fast, 4)),
        f(4, 11000, [92, 52], [16, 0], [1, 1], ev(0, .charged, 42)),
        f(5, 21000, [92, 10], [0, 0], [1, 0], ev(0, .charged, 45)),
        f(6, 31000, [92, 0], [0, 0], [1, 0], ev(0, .charged, 20)),
        f(6, 31000, [92, 0], [0, 0], [1, 0], ev(1, .faint)),
    ]
    let log = BattleLog(frames: frames, ratingA: 812, ratingB: 188,
                        hpA: 92, hpB: 0, energyA: 0, energyB: 0, shieldsA: 1, shieldsB: 0)
    let scenario = ShieldSearch.Solution(
        ratingA: 812, policyA: [1], policyB: [0],
        scenarioWins: 9, scenarioLosses: 2, scenarioTies: 0,
        scenarioCount: 11, bestCaseA: 900, worstCaseA: 420)
    return ScrollView {
        BattleTimelineView(
            log: log,
            sideA: BattleParticipant(name: "Kingdra", types: ["water", "dragon"]),
            sideB: BattleParticipant(name: "Cradily", types: ["rock", "grass"]),
            scenario: scenario)
        .padding()
    }
    .frame(width: 560, height: 600)
}
