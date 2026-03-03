import Foundation

public enum ConnectionState: Equatable, Sendable {
    case idle
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case bluetoothResetting
    case scanning
    case connecting(name: String?)
    case discovering(name: String?)
    case authenticating(name: String?)
    case connected(name: String?)
    case reconnecting(name: String?)
    case failed(message: String)
}

public enum ANCMode: String, CaseIterable, Codable, Equatable, Sendable {
    case on
    case transparency
    case off
}

public struct BatteryStatus: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var `case`: Int?
    public var lastUpdated: Date

    public init(left: Int?, right: Int?, case: Int?, lastUpdated: Date = Date()) {
        self.left = left
        self.right = right
        self.case = `case`
        self.lastUpdated = lastUpdated
    }

    public var averageLR: Int? {
        guard let l = left, let r = right else { return nil }
        return Int(((Double(l) + Double(r)) / 2.0).rounded(.toNearestOrAwayFromZero))
    }

    // Capacity-weighted total battery percent (your model):
    // Left: 58 mAh, Right: 58 mAh, Case: 440 mAh, Total: 556 mAh.
    public var totalWeightedPercent: Int? {
        let leftMah = 58.0
        let rightMah = 58.0
        let caseMah = 440.0

        var num = 0.0
        var den = 0.0

        if let l = left {
            num += (Double(l) / 100.0) * leftMah
            den += leftMah
        }
        if let r = right {
            num += (Double(r) / 100.0) * rightMah
            den += rightMah
        }
        if let c = `case` {
            num += (Double(c) / 100.0) * caseMah
            den += caseMah
        }
        guard den > 0 else { return nil }

        let pct = (num / den) * 100.0
        return Int(pct.rounded(.toNearestOrAwayFromZero))
    }

    public var minLR: Int? {
        guard let l = left, let r = right else { return nil }
        return min(l, r)
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public var statusByte: UInt8?
    public var lastUpdated: Date

    public init(statusByte: UInt8?, lastUpdated: Date = Date()) {
        self.statusByte = statusByte
        self.lastUpdated = lastUpdated
    }
}

public struct EQStatus: Equatable, Sendable {
    // Legacy: previously treated as a single mode byte. Kept for compatibility with older
    // callers but no longer used for UI.
    public var modeByte: UInt8?

    // Preset/band table (from EQ query response, typically ASCII CSV triplets).
    public var presets: [EQPreset]

    // Best-effort active preset. Some firmwares don't expose the active preset directly;
    // we keep the last user-selected preset here and optionally update it if we can verify.
    public var currentPreset: Int?
    public var lastUpdated: Date

    public init(modeByte: UInt8?, presets: [EQPreset] = [], currentPreset: Int? = nil, lastUpdated: Date = Date()) {
        self.modeByte = modeByte
        self.presets = presets
        self.currentPreset = currentPreset
        self.lastUpdated = lastUpdated
    }
}

public struct EQPreset: Equatable, Sendable, Identifiable {
    public var id: Int
    public var bands: [EQBand]

    public init(id: Int, bands: [EQBand]) {
        self.id = id
        self.bands = bands
    }
}

public struct EQBand: Equatable, Sendable, Identifiable {
    public var id: Int
    public var value: Int

    public init(id: Int, value: Int) {
        self.id = id
        self.value = value
    }
}

public enum UpdateSource: Sendable {
    case onOpen
    case user
    case device
}

public enum OperationKind: String, Sendable {
    case connect
    case authenticate
    case setANC
    case setEQPreset
    case queryANC
    case queryBattery
    case queryDeviceInfo
    case queryEQ
    case scanEQ
    case refreshAll
    case reconnect
}

public enum OperationPhase: Equatable, Sendable {
    case queued
    case running(step: String)
    case succeeded
    case failed(message: String)
}

public struct OperationEvent: Equatable, Sendable {
    public var id: UUID
    public var kind: OperationKind
    public var phase: OperationPhase
    public var timestamp: Date

    public init(id: UUID = UUID(), kind: OperationKind, phase: OperationPhase, timestamp: Date = Date()) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.timestamp = timestamp
    }
}

public struct UserFacingError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public enum BudsEvent: Sendable {
    case connection(ConnectionState)
    case anc(ANCMode, source: UpdateSource)
    case battery(BatteryStatus, source: UpdateSource)
    case deviceInfo(DeviceInfo)
    case eq(EQStatus)
    case operation(OperationEvent)
    case error(UserFacingError)
}
