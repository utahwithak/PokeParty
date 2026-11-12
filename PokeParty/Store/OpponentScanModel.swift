//
//  OpponentScanModel.swift
//  PokeParty
//
//  App-level state for the iPhone's Screen Scan tool: the screen capture, the
//  link to a Mac running Opponent Check, the opponents detected so far, and
//  IV readings from the appraisal screen. It lives above any one screen
//  because results keep arriving while the user is in Pokémon GO, with no
//  PokeParty view on screen to receive them — each new IV reading is
//  therefore also posted as a local notification.
//

#if os(iOS)

import CoreGraphics
import Foundation
import UserNotifications

@Observable
@MainActor
final class OpponentScanModel {
    let stream = OpponentScreenStream()
    let link = PhoneLinkClient()
    /// Reads IVs off appraisal-screen frames; shared with the Mac's Scan tool.
    let ivScan = ScanModel()

    /// Opponents detected this session, newest first.
    private(set) var detections: [OpponentDetection] = []
    /// Newest battle-header reading, for Battle HUD when it runs on this device (iPad).
    private(set) var latestSnapshot: BattleSnapshot?
    /// Called for every snapshot, in order (see `PhoneLinkServer.onSnapshot`).
    @ObservationIgnored var onSnapshot: (@MainActor (BattleSnapshot) -> Void)?
    /// Detections Opponent Check hasn't taken yet.
    @ObservationIgnored private var untaken: [OpponentDetection] = []

    /// Needed to resolve species and rank IVs; set when a scan begins.
    @ObservationIgnored private var store: RankingsStore?
    /// True while a frame is being read; frames arriving meanwhile are dropped.
    @ObservationIgnored private var isReadingFrame = false

    private static let maxStored = 20

    var isScanning: Bool { stream.isStreaming }

    init() {
        stream.onDetection = { [weak self] detection in
            self?.received(detection)
        }
        stream.onSnapshot = { [weak self] snapshot in
            self?.latestSnapshot = snapshot
            self?.onSnapshot?(snapshot)
            self?.link.send(snapshot)
        }
        stream.onAppraisalFrame = { [weak self] image in
            self?.readIVs(from: image)
        }
        ivScan.onNewHistoryEntry = { [weak self] entry in
            self?.notify(of: entry)
        }
    }

    func begin(store: RankingsStore) {
        self.store = store
        requestNotificationPermission()
        stream.present()
        // Also look for a Mac running Opponent Check.
        link.start()
    }

    func end() async {
        await stream.stop()
        link.stop()
    }

    func clear() {
        detections = []
        untaken = []
        ivScan.clearHistory()
    }

    /// Detections not yet handed to Opponent Check, oldest first.
    func takeUntaken() -> [OpponentDetection] {
        defer { untaken = [] }
        return untaken
    }

    private func received(_ detection: OpponentDetection) {
        detections.insert(detection, at: 0)
        if detections.count > Self.maxStored { detections.removeLast() }
        untaken.append(detection)
        link.send(detection)
    }

    // MARK: - IV reading

    private func readIVs(from image: CGImage) {
        guard let store, !isReadingFrame else { return }
        isReadingFrame = true
        Task {
            defer { isReadingFrame = false }
            // A frame Vision can't read is just skipped; the next one tries again.
            try? await ivScan.processFrame(image, store: store)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Posts the IV result the way a PokeGenie overlay would show it: the
    /// spread and percentage up top, the best league rank underneath.
    private func notify(of entry: ScanModel.HistoryEntry) {
        let ivs = entry.ivs
        let percent = Double(ivs.atk + ivs.def + ivs.hp) / 45 * 100

        let content = UNMutableNotificationContent()
        content.title = "\(entry.speciesName)  \(ivs.atk)/\(ivs.def)/\(ivs.hp)"
        var body = String(format: "%.1f%% IV", percent)
        if let hit = entry.bestRank {
            let evolved = hit.speciesName == entry.speciesName ? "" : " as \(hit.speciesName)"
            body += " · best rank #\(hit.rank) in \(hit.league.title) League\(evolved)"
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

#endif
