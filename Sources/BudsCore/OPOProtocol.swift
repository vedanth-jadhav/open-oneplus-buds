import Foundation

public enum OPOProtocol {
    public static let service079A = "0000079A-D102-11E1-9B23-00025B00A5A5"
    public static let write079A = "0100079A-D102-11E1-9B23-00025B00A5A5"
    public static let notify079A = "0200079A-D102-11E1-9B23-00025B00A5A5"

    // Observed FE2C characteristic from the script.
    public static let fe2cCommandChar = "FE2C123A-8366-4814-8EB0-01DE32100BEA"

    public static let registerToken: [UInt8] = [0xB5, 0x50, 0xA0, 0x69]

    public static func helloPacket() -> [UInt8] {
        [0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x00, 0x12]
    }

    public static func registerPacket(token: [UInt8] = registerToken) -> [UInt8] {
        [0xAA, 0x0C, 0x00, 0x00, 0x00, 0x85, 0x41, 0x05, 0x00, 0x00] + token
    }

    public static func ancQueryPacket() -> [UInt8] {
        // From the original script. Kept as-is.
        [0xAA, 0x09, 0x00, 0x00, 0x04, 0x82, 0x44, 0x02, 0x00, 0x00, 0xF2]
    }

    public static func ancSetPacket(modeByte: UInt8) -> [UInt8] {
        [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x42, 0x03, 0x00, 0x01, 0x01, modeByte]
    }

    public static func batteryQueryPacket() -> [UInt8] {
        [0xAA, 0x07, 0x00, 0x00, 0x06, 0x01, 0x25, 0x00, 0x00]
    }

    public static func deviceInfoQueryPacket() -> [UInt8] {
        [0xAA, 0x07, 0x00, 0x00, 0x03, 0x01, 0x28, 0x00, 0x00]
    }

    public static func eqQueryPacket() -> [UInt8] {
        [0xAA, 0x07, 0x00, 0x00, 0x05, 0x01, 0x2B, 0x00, 0x00]
    }

    public static func eqQueryPacket(cmd: UInt8) -> [UInt8] {
        [0xAA, 0x07, 0x00, 0x00, 0x05, 0x01, cmd, 0x00, 0x00]
    }

    public static func eqSetPresetPacket(preset: UInt8) -> [UInt8] {
        // Best-guess based on the CAT=0x05 query/response family where bytes[6] is a command id.
        // AA 0A 00 00 05 04 2B 03 00 01 01 <preset>
        [0xAA, 0x0A, 0x00, 0x00, 0x05, 0x04, 0x2B, 0x03, 0x00, 0x01, 0x01, preset]
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

public enum OPOParse {
    public static func parseBatteryTelemetry(_ bytes: [UInt8]) -> BatteryStatus? {
        // Some firmwares embed battery TLV pairs inside CAT=0x04 SUB=0x02 telemetry frames.
        // IMPORTANT: not every 0x08 0x00 block is battery percent. We only accept the frame
        // shape that matches observed battery-percent telemetry:
        // AA 0F .. .. 04 02 <seq> 08 00 01 <count> 01 <L> 02 <R> 03 <Case>
        guard bytes.count >= 17 else { return nil }
        guard bytes.first == 0xAA else { return nil }
        guard bytes[4] == 0x04, bytes[5] == 0x02 else { return nil }
        // The marker appears at fixed offsets on frames we've observed.
        guard bytes[7] == 0x08, bytes[8] == 0x00 else { return nil }
        // This discriminator byte appears to select the "battery percent" variant.
        guard bytes[9] == 0x01 else { return nil }

        let pairCount = Int(bytes[10])
        guard (1...3).contains(pairCount) else { return nil }

        let start = 11
        let need = start + pairCount * 2
        guard bytes.count >= need else { return nil }

        var left: Int?
        var right: Int?
        var c: Int?
        var sawCasePair = false

        var i = start
        for _ in 0..<pairCount {
            let id = bytes[i]
            let v = Int(bytes[i + 1])
            guard (0...100).contains(v) else { return nil }
            switch id {
            case 0x01: left = v
            case 0x02: right = v
            case 0x03:
                sawCasePair = true
                c = v
            default:
                // Unknown IDs: treat as non-battery telemetry to avoid false positives.
                return nil
            }
            i += 2
        }

        if sawCasePair, c == 0, (left ?? 0) > 5 || (right ?? 0) > 5 {
            c = nil
        }
        return BatteryStatus(left: left, right: right, case: c)
    }

    public static func parseBattery(_ bytes: [UInt8]) -> BatteryStatus? {
        // Battery responses are vendor frames:
        // AA .. .. .. CAT=0x06 SUB=0x81 CMD=0x25 ...
        guard bytes.count >= 12 else { return nil }
        guard bytes.first == 0xAA else { return nil }
        guard bytes[4] == 0x06, bytes[5] == 0x81, bytes[6] == 0x25 else { return nil }

        // Preferred decode: parse id/value pairs:
        // ... <count> 01 <L%> 02 <R%> 03 <Case%> ...
        // Observed examples:
        // AA 0F 00 00 06 81 25 08 00 00 03 01 64 02 64 03 00
        // AA 0D 00 00 06 81 25 06 00 00 02 01 64 03 00
        let pairCount = Int(bytes[10])
        let start = 11
        let need = start + pairCount * 2
        if pairCount > 0, bytes.count >= need {
            var left: Int?
            var right: Int?
            var c: Int?
            var sawCasePair = false

            var i = start
            for _ in 0..<pairCount {
                let id = bytes[i]
                let v = Int(bytes[i + 1])
                if (0...100).contains(v) {
                    switch id {
                    case 0x01: left = v
                    case 0x02: right = v
                    case 0x03:
                        sawCasePair = true
                        c = v
                    default: break
                    }
                }
                i += 2
            }

            if left != nil || right != nil || c != nil {
                // Heuristic: some firmwares report case as 0 when the case is not queryable
                // (buds are out of the case / lid closed). If buds have charge, treat 0 as unknown
                // so UI doesn't incorrectly show "0%" and tank the weighted total.
                if sawCasePair, c == 0, (left ?? 0) > 5 || (right ?? 0) > 5 {
                    c = nil
                }
                return BatteryStatus(left: left, right: right, case: c)
            }
        }

        // Fallback: legacy fixed-index parsing (from the original script).
        if bytes.count >= 16 {
            let left = Int(bytes[12])
            let right = Int(bytes[14])
            let c0 = Int(bytes[15])
            var c: Int? = c0
            guard (0...100).contains(left), (0...100).contains(right), (0...100).contains(c0) else { return nil }
            if c0 == 0, left > 5 || right > 5 { c = nil }
            return BatteryStatus(left: left, right: right, case: c)
        }

        // Short fallback: if only a left value is present, mirror it to right.
        if bytes.count >= 14 {
            let left = Int(bytes[12])
            let c0 = Int(bytes[13])
            var c: Int? = c0
            guard (0...100).contains(left), (0...100).contains(c0) else { return nil }
            if c0 == 0, left > 5 { c = nil }
            return BatteryStatus(left: left, right: left, case: c)
        }

        return nil
    }

    public static func parseDeviceInfo(_ bytes: [UInt8]) -> DeviceInfo? {
        guard bytes.count >= 8 else { return nil }
        guard bytes.first == 0xAA else { return nil }
        return DeviceInfo(statusByte: bytes[7])
    }

    public static func parseEQ(_ bytes: [UInt8]) -> EQStatus? {
        // EQ table responses on your buds look like:
        // AA .. 00 00 CAT=0x05 SUB=0x81 CMD=0x2B .. .. .. <tripletCount> <ascii csv...>
        // Example payload decodes to: "1,1,111,1,2,155,..."
        guard bytes.count >= 12 else { return nil }
        guard bytes.first == 0xAA else { return nil }
        guard bytes[4] == 0x05 else { return nil }

        // Strict parse for the observed EQ query response.
        if bytes.count >= 12, bytes[5] == 0x81, bytes[6] == 0x2B {
            let tripletCount = Int(bytes[10])
            guard (1...64).contains(tripletCount) else { return nil }

            let payload = Data(bytes[11...])
            guard let s = String(data: payload, encoding: .utf8) else { return nil }
            let parts = s.split(separator: ",", omittingEmptySubsequences: true)
            guard parts.count == tripletCount * 3 else { return nil }

            var triplets: [(preset: Int, band: Int, value: Int)] = []
            triplets.reserveCapacity(tripletCount)
            var i = 0
            while i < parts.count {
                guard
                    let p = Int(parts[i]),
                    let b = Int(parts[i + 1]),
                    let v = Int(parts[i + 2])
                else { return nil }
                triplets.append((p, b, v))
                i += 3
            }

            var byPreset: [Int: [EQBand]] = [:]
            for t in triplets {
                guard (1...16).contains(t.preset), (1...16).contains(t.band) else { continue }
                byPreset[t.preset, default: []].append(EQBand(id: t.band, value: t.value))
            }

            let presets = byPreset.keys.sorted().map { pid in
                let bands = (byPreset[pid] ?? []).sorted(by: { $0.id < $1.id })
                return EQPreset(id: pid, bands: bands)
            }

            return EQStatus(modeByte: nil, presets: presets, currentPreset: nil)
        }

        // Fallback: keep legacy behavior for any other CAT=0x05 frames we don't understand.
        if bytes.count >= 7 {
            return EQStatus(modeByte: bytes[6], presets: [], currentPreset: nil)
        }
        return nil
    }

    public static func parseANCModeByte(_ bytes: [UInt8]) -> UInt8? {
        // We treat packets as ANC status only when they match known vendor ANC shapes.
        // Avoids mis-classifying unrelated frames that just happen to contain 0x01/0x02/0x04.
        guard bytes.count >= 8 else { return nil }
        guard bytes.first == 0xAA else { return nil }
        guard bytes[4] == 0x04 else { return nil }
        let sub = bytes[5]
        switch sub {
        case 0x02:
            // ANC push-state frames observed during earbud/phone toggles tend to end with:
            // ... 03 01 01 <STATE>
            // Many other CAT=0x04 SUB=0x02 frames are telemetry and must be ignored.
            guard bytes.count >= 12 else { return nil }
            let n = bytes.count
            guard bytes[n - 4] == 0x03, bytes[n - 3] == 0x01, bytes[n - 2] == 0x01 else { return nil }
            return bytes[n - 1]

        case 0x81:
            // Response frames to queries: prefer the "set-like" tail marker:
            // ... 03 00 01 01 <MODE>
            for i in 6..<(bytes.count - 4) {
                if bytes[i] == 0x03, bytes[i + 1] == 0x00, bytes[i + 2] == 0x01, bytes[i + 3] == 0x01 {
                    return bytes[i + 4]
                }
            }
            return nil
        default:
            return nil
        }
    }
}
