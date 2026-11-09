//
//  OpponentCheckBadges.swift
//  PokeParty
//
//  Small badges and diagrams used by the Check Opponent view.
//

import StoreKit
import SwiftUI

/// Small "CMP" tag: whether you win a simultaneous charged-move tie against this opponent.
struct CMPBadge: View {
    let outlook: CMPOutlook

    private var detail: (symbol: String, color: Color, help: String) {
        switch outlook {
        case .alwaysWins:
            ("checkmark", Theme.win, "Always wins charge move priority: higher Attack than this opponent at any IVs.")
        case .ivDependent:
            ("questionmark", .orange, "Charge move priority depends on IVs: the Attack ranges overlap.")
        case .cannotWin:
            ("xmark", Theme.loss, "Can't win charge move priority: lower Attack than this opponent at any IVs.")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Text("CMP")
            Image(systemName: detail.symbol)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(detail.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(detail.color.opacity(0.15), in: Capsule())
        .help(detail.help)
        .accessibilityLabel(detail.help)
    }
}

/// Two-lane timeline of the optimal throw timing: the top lane is your fast
/// moves (the highlighted cell is where the charged move goes), the bottom
/// lane is the opponent's fast moves. Cell widths are proportional to
/// duration, so you can see where the opponent's move lands relative to yours.
struct ThrowTimingDiagram: View {
    let timed: [Int]
    let pokeFast: Move
    let opponentFast: Move

    private static let laneHeight: CGFloat = 14

    private struct Cell: Identifiable {
        let id: Int
        let turns: Int
        let isCharged: Bool
    }

    /// Own lane: `timed[i]` fast moves then a one-turn charged move,     /// many throws as fit (at least one, at most three).
    private var ownCells: [Cell] {
        var cells: [Cell] = []
        let pokeTurns = pokeFast.cooldown / 500
        for count in timed {
            for _ in 0..<count { cells.append(Cell(id: cells.count, turns: pokeTurns, isCharged: false)) }
            cells.append(Cell(id: cells.count, turns: 1, isCharged: true))
        }
        return cells
    }

    var body: some View {
        let own = ownCells
        let totalTurns = max(1, own.reduce(0) { $0 + $1.turns })
        let oppTurns = max(1, opponentFast.cooldown / 500)
        let oppCells = (0..<Int((Double(totalTurns) / Double(oppTurns)).rounded(.up)))
            .map { Cell(id: $0, turns: oppTurns, isCharged: false) }

        VStack(spacing: 2) {
            lane(own, totalTurns: totalTurns, fill: Color.yellow.opacity(0.25), highlight: Color.yellow.opacity(0.85))
            lane(oppCells, totalTurns: totalTurns, fill: Color.orange.opacity(0.65), highlight: .orange)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Optimal move timing: throw after \(ChargeTiming.formatThrowPoints(timed)) fast moves")
    }

    private func lane(_ cells: [Cell], totalTurns: Int, fill: Color, highlight: Color) -> some View {
        GeometryReader { geo in
            let unit = geo.size.width / CGFloat(totalTurns)
            HStack(spacing: 0) {
                ForEach(cells) { cell in
                    Rectangle()
                        .fill(cell.isCharged ? highlight : fill)
                        .overlay(Rectangle().stroke(cell.isCharged ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.5),
                                                    lineWidth: cell.isCharged ? 1.5 : 1))
                        .frame(width: unit * CGFloat(cell.turns))
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
        }
        .frame(height: Self.laneHeight)
    }
}

/// "FAINTED" tag laid over a greyed-out Pokémon card.
struct FaintedBadge: View {
    var body: some View {
        Text("FAINTED")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.85), in: Capsule())
    }
}
