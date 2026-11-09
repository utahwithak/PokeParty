//
//  PhoneLink.swift
//  PokeParty
//
//  A small local-network link from the iPhone to the Mac. While Opponent
//  Check is open on the Mac it advertises a Bonjour service
//  (`PhoneLinkServer`); the iPhone, while it's detecting opponents from the
//  Pokémon GO screen, finds it and sends each detection across
//  (`PhoneLinkClient`). The Mac then fills in Opponent Check exactly as the
//  phone would. Messages are newline-delimited JSON over plain TCP.
//

import Foundation
import Network

/// An opponent read off the battle screen — raw OCR text, not yet a species.
nonisolated struct OpponentDetection: Equatable, Identifiable, Sendable {
    let id = UUID()
    var name: String
    var cp: Int?
    /// Fill colours of the type icons, left to right (see `OpponentTypeReader`).
    var icons: [IconColor] = []

    /// Nearest-known-type guesses for the icons, for the debug readout only.
    var iconSummary: String {
        icons.map { icon in
            let guess = TypeColors.nearest(to: icon).map { "\($0.type) Δ\(Int($0.distance))" } ?? "?"
            return "(\(Int(icon.r)),\(Int(icon.g)),\(Int(icon.b))) ≈ \(guess)"
        }.joined(separator: "  ")
    }
}

/// A line of text OCR'd off the battle screen, and how far down the screen it
/// was (0 top … 1 bottom).
nonisolated struct ScreenLine: Codable, Equatable, Sendable {
    var text: String
    var y: Double
}

/// What the phone reads off the battle header on a frame: your active
/// Pokémon's raw name and type icons, shields and Pokémon left on each side,
/// and the effectiveness label if one was showing. HP and energy aren't here.
nonisolated struct BattleSnapshot: Codable, Equatable, Sendable {
    var myName: String?
    var myIcons: [IconColor]
    /// Header readings; nil when the header wasn't readable on this frame.
    var myShields: Int?
    var opponentShields: Int?
    var myAlive: Int?
    var opponentAlive: Int?
    var flash: EffectivenessFlash?
    /// HP left on each active Pokémon (0…1), when its bar was found.
    var myHP: Double?
    var opponentHP: Double?
    /// Names from "<name> fainted" messages showing on this frame.
    var fainted: [String] = []
    /// Every line of text read off the middle of the screen, each sent once per
    /// showing. The Mac pulls charged-move banners out of it (it knows which
    /// Pokémon are out) and keeps the rest with the game for tuning.
    var screenText: [ScreenLine]? = nil
    /// How far down the screen the effectiveness label was (0 top … 1 bottom);
    /// it sits over whoever was hit, so the upper half is the opponent.
    var flashY: Double? = nil
    /// "YOU WIN!" / "Good Effort" when the result screen was showing.
    var result: BattleOutcome? = nil
}

nonisolated enum PhoneLink {
    static let serviceType = "_pokeparty._tcp"
}

nonisolated enum PhoneLinkMessage: Codable, Sendable {
    /// First message on a connection, so the Mac can show who's connected.
    case hello(deviceName: String)
    case opponent(name: String, cp: Int?, icons: [IconColor])
    case snapshot(BattleSnapshot)
}

// MARK: - Framing

/// Splits a TCP byte stream into newline-terminated messages.
nonisolated private struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
        }
        // A peer that never sends a newline shouldn't grow this without bound.
        if pending.count > 256 * 1024 { pending.removeAll() }
        return lines
    }
}

/// Reads messages off a connection until it ends. One receive is in flight at
/// a time, so the buffer never sees concurrent access.
nonisolated private final class MessageReader: @unchecked Sendable {
    private let connection: NWConnection
    private let onMessage: @Sendable (PhoneLinkMessage) -> Void
    private let onEnd: @Sendable () -> Void
    private var buffer = LineBuffer()

    init(connection: NWConnection,
         onMessage: @escaping @Sendable (PhoneLinkMessage) -> Void,
         onEnd: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.onMessage = onMessage
        self.onEnd = onEnd
    }

    func run() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data {
                for line in buffer.append(data) {
                    if let message = try? JSONDecoder().decode(PhoneLinkMessage.self, from: line) {
                        onMessage(message)
                    }
                }
            }
            if error != nil || isComplete {
                onEnd()
            } else {
                run()
            }
        }
    }
}

nonisolated private func sendMessage(_ message: PhoneLinkMessage, on connection: NWConnection) {
    guard var data = try? JSONEncoder().encode(message) else { return }
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { _ in })
}

// MARK: - Mac / iPad: listener

/// Runs while Opponent Check is on screen. Accepts one phone at a time (a
/// newer connection replaces the old one) and publishes what it sends.
@Observable
@MainActor
final class PhoneLinkServer {
    enum State: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    private(set) var state: State = .stopped
    /// The connected phone's name, or nil when none is connected.
    private(set) var phoneName: String?
    private(set) var latest: OpponentDetection?
    /// Newest battle-header reading from the phone.
    private(set) var latestSnapshot: BattleSnapshot?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var reader: MessageReader?
    @ObservationIgnored private let queue = DispatchQueue(label: "PokeParty.PhoneLinkServer")

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(type: PhoneLink.serviceType)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in self?.listenerStateChanged(newState) }
            }
            listener.newConnectionHandler = { [weak self] newConnection in
                Task { @MainActor in self?.accept(newConnection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        dropConnection()
        state = .stopped
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready: state = .listening
        case .failed(let error):
            state = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        default: break
        }
    }

    private func accept(_ newConnection: NWConnection) {
        dropConnection()
        connection = newConnection

        let reader = MessageReader(
            connection: newConnection,
            onMessage: { [weak self] message in
                Task { @MainActor in self?.received(message, from: newConnection) }
            },
            onEnd: { [weak self] in
                Task { @MainActor in self?.ended(newConnection) }
            })
        self.reader = reader
        newConnection.start(queue: queue)
        reader.run()
    }

    private func received(_ message: PhoneLinkMessage, from source: NWConnection) {
        guard source === connection else { return }
        switch message {
        case .hello(let deviceName):
            phoneName = deviceName
        case .opponent(let name, let cp, let icons):
            latest = OpponentDetection(name: name, cp: cp, icons: icons)
        case .snapshot(let snapshot):
            latestSnapshot = snapshot
        }
    }

    private func ended(_ source: NWConnection) {
        guard source === connection else { return }
        dropConnection()
    }

    private func dropConnection() {
        connection?.cancel()
        connection = nil
        reader = nil
        phoneName = nil
    }
}

// MARK: - iPhone: browser + client

#if os(iOS)

import UIKit

/// Looks for a Mac advertising the service and, once found, sends it
/// detections. Reconnects on its own while running.
@Observable
@MainActor
final class PhoneLinkClient {
    /// The connected Mac's name, or nil when not connected.
    private(set) var macName: String?
    private(set) var isSearching = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var results: [NWBrowser.Result] = []
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private let queue = DispatchQueue(label: "PokeParty.PhoneLinkClient")

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: PhoneLink.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let results = Array(results)
            Task { @MainActor in
                self?.results = results
                self?.connectIfNeeded()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        isSearching = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        results = []
        connection?.cancel()
        connection = nil
        macName = nil
        isSearching = false
    }

    func send(_ detection: OpponentDetection) {
        guard let connection, macName != nil else { return }
        sendMessage(.opponent(name: detection.name, cp: detection.cp, icons: detection.icons), on: connection)
    }

    func send(_ snapshot: BattleSnapshot) {
        guard let connection, macName != nil else { return }
        sendMessage(.snapshot(snapshot), on: connection)
    }

    private func connectIfNeeded() {
        // An iPad running Battle HUD advertises the service too; don't connect to ourselves.
        let ownName = UIDevice.current.name
        let others = results.filter { result in
            if case .service(let serviceName, _, _, _) = result.endpoint { return serviceName != ownName }
            return true
        }
        guard connection == nil, let result = others.first else { return }
        let name: String
        if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName } else { name = "Mac" }

        let newConnection = NWConnection(to: result.endpoint, using: .tcp)
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.connectionStateChanged(state, connection: newConnection, macName: name) }
        }
        newConnection.start(queue: queue)
    }

    private func connectionStateChanged(_ state: NWConnection.State, connection source: NWConnection, macName name: String) {
        guard source === connection else { return }
        switch state {
        case .ready:
            macName = name
            sendMessage(.hello(deviceName: UIDevice.current.name), on: source)
        case .failed, .cancelled:
            source.cancel()
            connection = nil
            macName = nil
            // Try again shortly (the Mac may have just closed Opponent Check).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if browser != nil { connectIfNeeded() }
            }
        default:
            break
        }
    }
}

#endif
