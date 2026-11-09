//
//  BattleHUDCoachBar.swift
//  PokeParty
//
//  Coach bar chrome for the Battle HUD: divider, connection status row and banner.
//

import SwiftUI

/// The line between the main panel and the coaching bar. Drag it left or right
/// to resize the bar; double-click resets it to the default width.
struct CoachBarDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// The bar's width when the current drag began.
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Divider()
            // A wider, invisible grab area around the 1pt line.
            .overlay {
                Rectangle()
                    .fill(hovering || startWidth != nil ? Color.accentColor.opacity(0.35) : .clear)
                    .frame(width: 4)
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? width
                        startWidth = start
                        // The bar is on the right, so dragging left makes it wider.
                        width = min(max(start - drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { width = 340 }
            .help("Drag to resize the coaching bar. Double-click to reset.")
    }
}

/// iPhone connection status, kept at the top so it's obvious whether the
/// phone is feeding the coach. Expands to setup instructions.
struct CoachConnectionRow: View {
    let phoneLink: PhoneLinkServer
    let store: RankingsStore
    @State private var showInfo = false
    #if os(iOS)
    /// iPad: this device's own Screen Scan, started and stopped from here.
    @Environment(OpponentScanModel.self) private var scan
    #endif

    private var deviceName: String {
        #if os(macOS)
        "this Mac"
        #else
        "this iPad"
        #endif
    }

    private var status: (text: String, color: Color) {
        #if os(iOS)
        if scan.isScanning { return ("Scanning this iPad's screen", .green) }
        #endif
        if let name = phoneLink.phoneName { return ("Connected to \(name)", .green) }
        switch phoneLink.state {
        case .listening: return ("Waiting for iPhone", .orange)
        case .failed: return ("iPhone link unavailable", .red)
        case .stopped: return ("iPhone link off", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            card
            #if os(iOS)
            // Why a scan didn't start (e.g. no screen capture on the simulator).
            if let message = scan.stream.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            #endif
        }
    }

    private var card: some View {
        let status = status
        return DisclosureGroup(isExpanded: $showInfo) {
            VStack(alignment: .leading, spacing: 6) {
                #if os(iOS)
                Text("Tap Begin Scan, choose Entire Screen, then open Pokémon GO next to PokeParty in Split View or Slide Over. This iPad reads the battle itself and fills in the opponent slots below.")
                #endif
                Text("Your iPhone can also send the opponent it sees in a Pokémon GO battle straight to \(deviceName), which fills in the opponent slots below.")
                Text("On iPhone: open PokeParty → Screen Scan, choose Entire Screen, then start a battle. Both devices need to be on the same Wi-Fi network, and the iPhone needs iOS 27.")
                if case .failed(let message) = phoneLink.state {
                    Text(message).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text(status.text)
                    .font(.subheadline.weight(.medium))
                Circle().fill(status.color).frame(width: 8, height: 8)
                #if os(iOS)
                Spacer()
                Button(scan.isScanning ? "Stop Scan" : "Begin Scan") {
                    if scan.isScanning {
                        Task { await scan.end() }
                    } else {
                        scan.begin(store: store)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(scan.isScanning ? .red : .accentColor)
                .controlSize(.small)
                #endif
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The tip itself — big enough to read at a glance mid-battle.
struct CoachBanner: View {
    let coach: BattleCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .foregroundStyle(tint)
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // In a corner overlay, not the stack, so it appearing doesn't resize the banner.
        .overlay(alignment: .topTrailing) {
            ProgressView()
                .controlSize(.small)
                .padding(14)
                .opacity(coach.phase == .thinking ? 1 : 0)
        }
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.4), lineWidth: 2))
        .animation(.easeOut(duration: 0.2), value: headline)
    }

    private var isSwitch: Bool {
        if case .switchTo? = coach.advice?.recommended.action { return true }
        return false
    }

    private var tint: Color {
        guard coach.advice != nil, coach.phase == .ready || coach.phase == .thinking else { return .secondary }
        return isSwitch ? .orange : .green
    }

    private var headline: String {
        switch coach.phase {
        case .needsTeam: return "Build your team"
        case .needsOpponent: return "Add the opponent"
        case .needsActive: return "Pick your active Pokémon"
        case .failed: return "No advice"
        case .thinking, .ready: return coach.advice?.headline ?? "Thinking…"
        }
    }

    private var detail: String {
        switch coach.phase {
        case .needsTeam: return "Add up to three Pokémon in Team Builder."
        case .needsOpponent: return "Search for the opponent below, or detect them from your iPhone."
        case .needsActive: return "The Pokémon marked as active is also marked fainted."
        case .failed(let message): return message
        case .thinking, .ready:
            guard let advice = coach.advice else { return "Simulating this matchup…" }
            return advice.detail
        }
    }
}
