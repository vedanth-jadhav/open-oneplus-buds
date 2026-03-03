import Foundation
import SwiftUI
import BudsCore
import AppKit

@MainActor
final class AppModel: ObservableObject {
    private let client: BudsClient
    private var eventTask: Task<Void, Never>?
    private var lastOnOpenBatteryQueryAt: Date?
    private var lastOnOpenANCQueryAt: Date?
    private var popoverIsOpen = false
    private var popoverCloseTask: Task<Void, Never>?
    private let debugEnabled = ProcessInfo.processInfo.environment["BUDS_DEBUG"] == "1"

    @Published var connection: ConnectionState = .idle
    @Published var anc: ANCMode?

    @Published var battery: BatteryStatus?

    @Published var lastOperation: OperationEvent?
    @Published var lastError: String?

    static let lowBatteryThreshold = 20
    private static let caseCachePercentKey = "buds.caseBatteryPercent"
    private static let caseCacheTimestampKey = "buds.caseBatteryTimestamp"
    private static let caseCacheMaxAge: TimeInterval = 12 * 60 * 60 // 12h

    init(client: BudsClient = BudsClientImpl()) {
        self.client = client
        client.start()

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await ev in client.events {
                self.handle(ev)
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    func onPopoverOpen() {
        popoverIsOpen = true
        popoverCloseTask?.cancel()
        popoverCloseTask = nil
        if debugEnabled { print("[UI] Popover open") }

        client.setLiveUpdatesEnabled(true)

        guard case .connected = connection else { return }

        let now = Date()
        let batteryFresh = (battery?.lastUpdated).map { now.timeIntervalSince($0) < 5 * 60 } ?? false
        let canQueryBattery = lastOnOpenBatteryQueryAt.map { now.timeIntervalSince($0) > 20 } ?? true
        let canQueryANC = lastOnOpenANCQueryAt.map { now.timeIntervalSince($0) > 20 } ?? true

        // Give CoreBluetooth a moment to apply notify state before sending queries.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))

            if !batteryFresh, canQueryBattery {
                self.lastOnOpenBatteryQueryAt = Date()
                self.client.queryBattery(source: .onOpen)
            }

            // If we don't yet know ANC state (some firmwares don't push it immediately),
            // do a one-shot query on open, rate-limited to avoid spam.
            if self.anc == nil, canQueryANC {
                self.lastOnOpenANCQueryAt = Date()
                self.client.queryANC(source: .onOpen)
            }
        }
    }

    func onPopoverClose() {
        popoverIsOpen = false
        if debugEnabled { print("[UI] Popover close (scheduled)") }
        popoverCloseTask?.cancel()
        popoverCloseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !self.popoverIsOpen else { return }
            if self.debugEnabled { print("[UI] Popover close (apply)") }
            self.client.setLiveUpdatesEnabled(false)
        }
    }

    func setANC(_ mode: ANCMode) {
        lastError = nil
        client.setANC(mode)
    }

    func refreshBattery() {
        lastError = nil
        client.queryBattery(source: .user)
    }

    func reconnect() {
        lastError = nil
        client.reconnectNow()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    var menuBatteryText: String? {
        guard case .connected = connection else { return nil }
        guard let total = displayBattery?.totalWeightedPercent else { return nil }
        var text = "\(total)%"
        if total < Self.lowBatteryThreshold {
            text += "!"
        }
        return text
    }

    var menuAccessibilityLabel: String {
        var parts: [String] = ["Buds"]
        if let bt = menuBatteryText {
            parts.append("Battery \(bt.replacingOccurrences(of: "!", with: "")) percent")
        }
        if let anc {
            switch anc {
            case .on: parts.append("Noise Cancellation On")
            case .transparency: parts.append("Transparency")
            case .off: parts.append("Noise Control Off")
            }
        }
        return parts.joined(separator: ", ")
    }

    var ancKnown: Bool { anc != nil }

    // Battery as shown in UI: if case % is unavailable, optionally fall back to last known
    // value so the user still sees a reasonable case % (marked as stale).
    var displayBattery: BatteryStatus? {
        guard let b = battery else { return nil }
        if b.case != nil { return b }
        guard let cached = cachedCasePercent, let ts = cachedCaseTimestamp else { return b }
        if Date().timeIntervalSince(ts) > Self.caseCacheMaxAge { return b }
        return BatteryStatus(left: b.left, right: b.right, case: cached, lastUpdated: b.lastUpdated)
    }

    private var cachedCasePercent: Int? {
        let v = UserDefaults.standard.object(forKey: Self.caseCachePercentKey) as? Int
        return v
    }

    private var cachedCaseTimestamp: Date? {
        return UserDefaults.standard.object(forKey: Self.caseCacheTimestampKey) as? Date
    }

    private func updateCaseCacheIfNeeded(_ b: BatteryStatus) {
        guard let c = b.case else { return }
        UserDefaults.standard.set(c, forKey: Self.caseCachePercentKey)
        UserDefaults.standard.set(Date(), forKey: Self.caseCacheTimestampKey)
    }

    private func handle(_ ev: BudsEvent) {
        switch ev {
        case .connection(let s):
            connection = s
            if case .connected = s {
                lastError = nil
            }
            // New/transitioning connection state: drop ANC so we don't display stale mode.
            switch s {
            case .idle, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported, .bluetoothResetting, .scanning, .failed:
                anc = nil
            default:
                break
            }
            switch s {
            case .bluetoothOff:
                lastError = "Bluetooth is off"
            case .bluetoothUnauthorized:
                lastError = "Bluetooth permission needed"
            case .bluetoothUnsupported:
                lastError = "Bluetooth unsupported"
            default:
                break
            }
        case .anc(let m, _):
            anc = m
        case .battery(let b, _):
            battery = b
            updateCaseCacheIfNeeded(b)
        case .deviceInfo:
            // Device section removed from UI; ignore.
            break
        case .eq:
            // EQ section removed from UI; ignore.
            break
        case .operation(let op):
            lastOperation = op
            if case .failed(let msg) = op.phase {
                lastError = msg
            }
        case .error(let err):
            lastError = err.message
        }
    }
}
