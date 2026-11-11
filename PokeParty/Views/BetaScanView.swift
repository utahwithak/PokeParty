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
        try await mirroringWindowTarget().frame
    }

    /// The window's frame plus the app that owns it.
    private func mirroringWindowTarget() async throws -> (frame: CGRect, app: NSRunningApplication?) {
        let content = try await SCShareableContent.current
        guard let window = findMirroringWindow(in: content) else {
            throw ScanError.windowNotFound
        }
        let app = window.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
        return (window.frame, app)
    }

    /// Brings `app` to the front and waits until it's frontmost. Goes
    /// through `NSWorkspace.openApplication` because, unlike
    /// `NSRunningApplication.activate`, it works while PokeParty itself is in
    /// the background.
    private func bringToFront(_ app: NSRunningApplication) async {
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Let the window finish raising before events land on it.
        try? await Task.sleep(for: .milliseconds(100))
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

    /// Swipes from the mid-right toward the mid-left of the mirroring window
    /// — the gesture Pokémon GO's detail screen uses to advance to the next
    /// Pokémon. Vertically centered so the drag lands on the card itself
    /// rather than a header panel that can swallow it as a tap. Synthetic
    /// events land on whichever window is under the cursor, so if iPhone
    /// Mirroring isn't frontmost it's raised for the swipe and the app the
    /// user was in is brought back afterward.
    func swipeToNextPokemon() async throws {
        guard hasAccessibilityAccess(prompt: true) else {
            throw BetaScanError.accessibilityDenied
        }
        let target = try await mirroringWindowTarget()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let raised = if let app = target.app, previousApp?.processIdentifier != app.processIdentifier {
            true
        } else {
            false
        }
        if raised, let app = target.app {
            await bringToFront(app)
        }
        defer {
            if raised, let previousApp {
                Task { await bringToFront(previousApp) }
            }
        }
        // Re-read the frame: raising the window can move or resize it.
        let frame = try await mirroringWindowFrame()
        let y = frame.minY + frame.height * 0.5
        let start = CGPoint(x: frame.minX + frame.width * 0.85, y: y)
        let end = CGPoint(x: frame.minX + frame.width * 0.15, y: y)
        try await postDrag(from: start, to: end)
    }

    /// Posts a mouseDown at `start`, interpolated mouseDragged events toward
    /// `end`, then a mouseUp — indistinguishable to the receiving app from a
    /// real trackpad/mouse drag. iPhone Mirroring ignores events posted
    /// straight to its process (`postToPid`), so the drag goes through the
    /// HID tap and moves the real cursor; it's decoupled from the mouse
    /// while the drag runs and warped back to where it was afterward.
    private func postDrag(from start: CGPoint, to end: CGPoint, steps: Int = 12) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw BetaScanError.inputSynthesisFailed
        }
        source.localEventsSuppressionInterval = 0
        let originalLocation = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            if let originalLocation {
                CGWarpMouseCursorPosition(originalLocation)
            }
            CGAssociateMouseAndMouseCursorPosition(1)
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
    /// Per-league stop criteria: auto-advance stops once the current
    /// Pokémon ranks `maxRank` or better in a league *and* its build there
    /// reaches at least `minCP`.
    struct LeagueCriteria: Codable {
        var maxRank: Int
        var minCP: Int
    }
    private static let defaultCriteria: [CheckLeague: LeagueCriteria] = [
        .great: LeagueCriteria(maxRank: 100, minCP: 1400),
        .ultra: LeagueCriteria(maxRank: 100, minCP: 2300),
        .master: LeagueCriteria(maxRank: 100, minCP: 3000),
    ]
    private static let criteriaDefaultsKey = "betaScan.autoAdvanceCriteria"

    /// Persisted to UserDefaults (keyed by league cap) on every change.
    var criteria: [CheckLeague: LeagueCriteria] {
        didSet {
            let encodable = Dictionary(uniqueKeysWithValues: criteria.map { (String($0.key.rawValue), $0.value) })
            if let data = JSONFileStore.encode(encodable) {
                UserDefaults.standard.set(data, forKey: Self.criteriaDefaultsKey)
            }
        }
    }

    init() {
        var loaded = Self.defaultCriteria
        if let data = UserDefaults.standard.data(forKey: Self.criteriaDefaultsKey),
           let stored = JSONFileStore.decode([String: LeagueCriteria].self, from: data) {
            for (key, value) in stored {
                if let raw = Int(key), let league = CheckLeague(rawValue: raw) { loaded[league] = value }
            }
        }
        criteria = loaded
    }
    static let criteriaLeagues: [CheckLeague] = [.great, .ultra, .master]

    private func criteriaBinding(_ league: CheckLeague) -> LeagueCriteria {
        criteria[league] ?? LeagueCriteria(maxRank: 0, minCP: 0)
    }

    func maxRankBinding(_ league: CheckLeague) -> Binding<Int> {
        Binding(
            get: { self.criteriaBinding(league).maxRank },
            set: { self.criteria[league, default: self.criteriaBinding(league)].maxRank = $0 })
    }

    func minCPBinding(_ league: CheckLeague) -> Binding<Int> {
        Binding(
            get: { self.criteriaBinding(league).minCP },
            set: { self.criteria[league, default: self.criteriaBinding(league)].minCP = $0 })
    }
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
        let criteria = criteria
        let hit = scan.bestRankHit(store: store) { league, result in
            guard let c = criteria[league] else { return false }
            return result.rank <= c.maxRank && result.combo.cp >= c.minCP
        }
        if let hit {
            pausedReason = "Rank #\(hit.rank) in \(hit.league.title) League as \(hit.speciesName) — auto-advance stopped."
            isEnabled = false
            return
        }
        guard scan.bestRankHit(store: store) != nil else { return }
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AutoAdvanceModel.criteriaLeagues) { league in
                        HStack(spacing: 6) {
                            Text("\(league.short): pause at rank")
                            TextField("Rank", value: autoAdvance.maxRankBinding(league), format: .number)
                                .frame(width: 50)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Text("or better, CP ≥")
                            TextField("CP", value: autoAdvance.minCPBinding(league), format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                        }
                    }
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
