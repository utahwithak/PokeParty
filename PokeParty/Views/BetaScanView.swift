//
//  BetaScanView.swift
//  PokeParty
//
//  Beta Scan: the Scan tool plus auto-advance, which posts synthetic mouse
//  drags into iPhone Mirroring to swipe to the next Pokémon. Synthesized
//  input into another app isn't allowed in App Store builds, so everything
//  here is compiled only when BETA_SCAN is defined (Debug and the "Direct"
//  configuration — never Release).
//

#if os(macOS) && BETA_SCAN

import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

enum BetaScanError: LocalizedError {
    case accessibilityDenied
    case inputSynthesisFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Accessibility permission is required to auto-advance. Grant access in System Settings → Privacy & Security → Accessibility, then try again."
        case .inputSynthesisFailed:
            "Couldn't send the swipe gesture to iPhone Mirroring."
        }
    }
}

// MARK: - Input synthesis

extension ScreenScanner {
    /// The iPhone Mirroring window's current on-screen frame, in the same
    /// global-display coordinate space `CGEventPost` expects.
    private func mirroringWindowFrame() async throws -> CGRect {
        let content = try await SCShareableContent.current
        guard let window = findMirroringWindow(in: content) else {
            throw ScanError.windowNotFound
        }
        return window.frame
    }

    /// Whether this process has the Accessibility permission needed to post
    /// synthetic mouse events into other applications — separate from the
    /// Screen Recording permission used for capture. `prompt: true` shows
    /// the system dialog the first time.
    func hasAccessibilityAccess(prompt: Bool) -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt`; the C global itself
        // is flagged as shared mutable state under Swift 6.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// True when the mouse cursor is over the iPhone Mirroring window. Each
    /// swipe relocates the real system cursor, so auto-advance pauses once
    /// the user's mouse has moved elsewhere.
    func isMouseOverMirroringWindow() async -> Bool {
        guard let frame = try? await mirroringWindowFrame() else { return false }
        let location = CGEvent(source: nil)?.location ?? .zero
        return frame.contains(location)
    }

    /// Swipes from the mid-right toward the mid-left of the mirroring window
    /// — the gesture Pokémon GO's detail screen uses to advance to the next
    /// Pokémon. Vertically centered so the drag lands on the card itself
    /// rather than a header panel that can swallow it as a tap.
    func swipeToNextPokemon() async throws {
        guard hasAccessibilityAccess(prompt: true) else {
            throw BetaScanError.accessibilityDenied
        }
        let frame = try await mirroringWindowFrame()
        let y = frame.minY + frame.height * 0.5
        let start = CGPoint(x: frame.minX + frame.width * 0.85, y: y)
        let end = CGPoint(x: frame.minX + frame.width * 0.15, y: y)
        try await postDrag(from: start, to: end)
    }

    /// Posts a mouseDown at `start`, interpolated mouseDragged events toward
    /// `end`, then a mouseUp — indistinguishable to the receiving app from a
    /// real trackpad/mouse drag.
    private func postDrag(from start: CGPoint, to end: CGPoint, steps: Int = 12) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw BetaScanError.inputSynthesisFailed
        }
        func post(_ type: CGEventType, at point: CGPoint) throws {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left
            ) else {
                throw BetaScanError.inputSynthesisFailed
            }
            event.post(tap: .cghidEventTap)
        }
        try post(.leftMouseDown, at: start)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            try post(.leftMouseDragged, at: point)
            try await Task.sleep(for: .milliseconds(12))
        }
        try post(.leftMouseUp, at: end)
    }
}

// MARK: - Auto-advance model

@MainActor
@Observable
final class AutoAdvanceModel {
    /// Master toggle; off by default so opening Beta Scan doesn't start
    /// swiping through the box unexpectedly.
    var isEnabled = false
    /// Auto-advance stops once the current Pokémon's best rank across
    /// Great/Ultra/Master League is at or better than this.
    var threshold = 100
    /// Why auto-advance stopped or is holding off; cleared when it resumes.
    var pausedReason: String?
    /// Set when the swipe itself fails — kept apart from the scan's live
    /// status so a swipe failure doesn't hide the Pokémon just found.
    var swipeError: String?
    /// True when `swipeError` is the missing-Accessibility case, so the view
    /// can offer a shortcut into System Settings.
    var swipeErrorNeedsAccessibility = false

    /// Only used for input synthesis; capture/OCR live on ScanModel's own scanner.
    private let scanner = ScreenScanner()

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { pausedReason = nil }
    }

    /// Hooks into `scan` so each newly committed reading can trigger a swipe.
    func attach(to scan: ScanModel, store: RankingsStore) {
        scan.onReadingCommitted = { [weak self, weak scan] in
            guard let self, let scan else { return }
            await self.handleCommittedReading(scan: scan, store: store)
        }
    }

    func detach(from scan: ScanModel) {
        scan.onReadingCommitted = nil
        isEnabled = false
        pausedReason = nil
    }

    /// Swipes to the next Pokémon once the scan has determined a species and
    /// IVs — never on a still-resolving or unrecognized read. Turns itself
    /// off once the current Pokémon's best rank meets `threshold`, so a good
    /// find can't start swiping again on its own. Holds off (without
    /// disabling) while the mouse is outside the mirroring window, since a
    /// swipe visibly relocates the real cursor.
    private func handleCommittedReading(scan: ScanModel, store: RankingsStore) async {
        guard isEnabled else { return }
        guard case .found(let live) = scan.liveStatus, live.speciesId != nil else { return }
        let barsComplete = live.barIVs?.atk != nil && live.barIVs?.def != nil && live.barIVs?.hp != nil
        guard barsComplete || !live.candidates.isEmpty else { return }
        guard let hit = scan.bestRankHit(store: store) else { return }
        if hit.rank <= threshold {
            pausedReason = "Rank #\(hit.rank) in \(hit.league.title) League as \(hit.speciesName) — auto-advance stopped."
            isEnabled = false
            return
        }
        guard await scanner.isMouseOverMirroringWindow() else {
            pausedReason = "Move the mouse back over iPhone Mirroring to resume auto-advance."
            return
        }
        pausedReason = nil
        if !(await performSwipe()) {
            // Swiping is broken (e.g. permission not granted) — stop
            // retrying and surfacing the same failure over and over.
            isEnabled = false
        }
    }

    /// Fires one swipe regardless of the toggle — backs "Swipe to Next".
    func advanceManually() {
        Task { await performSwipe() }
    }

    @discardableResult
    private func performSwipe() async -> Bool {
        do {
            try await scanner.swipeToNextPokemon()
            swipeError = nil
            swipeErrorNeedsAccessibility = false
            return true
        } catch BetaScanError.accessibilityDenied {
            swipeError = BetaScanError.accessibilityDenied.localizedDescription
            swipeErrorNeedsAccessibility = true
        } catch let error as LocalizedError {
            swipeError = error.errorDescription
            swipeErrorNeedsAccessibility = false
        } catch {
            swipeError = "Couldn't send the swipe gesture: \(error.localizedDescription)"
            swipeErrorNeedsAccessibility = false
        }
        return false
    }
}

// MARK: - Content column

/// The regular live scan view with the auto-advance controls above it.
struct BetaScanLiveView: View {
    let store: RankingsStore
    let model: ScanModel
    @Bindable var autoAdvance: AutoAdvanceModel

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            ScanLiveView(store: store, model: model)
        }
        .navigationTitle("Beta Scan")
        .onAppear { autoAdvance.attach(to: model, store: store) }
        .onDisappear { autoAdvance.detach(from: model) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                Toggle("Auto-Advance", isOn: Binding(
                    get: { autoAdvance.isEnabled },
                    set: { autoAdvance.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                Spacer()
                Button("Swipe to Next") { autoAdvance.advanceManually() }
                    .buttonStyle(.bordered)
            }
            if autoAdvance.isEnabled {
                HStack(spacing: 6) {
                    Text("Pause at rank")
                    TextField("Rank", value: $autoAdvance.threshold, format: .number)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Text("or better")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let reason = autoAdvance.pausedReason {
                Label(reason, systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = autoAdvance.swipeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                if autoAdvance.swipeErrorNeedsAccessibility {
                    Button("Open Accessibility Settings") { openAccessibilitySettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    /// Deep-links straight to Privacy & Security → Accessibility.
    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

#endif
