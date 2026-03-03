import Foundation

// Hardcoded mapping for your device (observed):
// When sending ANC_SET from the Mac app:
// - 0x02 results in ANC On
// - 0x04 results in Transparency
// - 0x01 results in Off
//
// Query responses (SUB=0x81) use the same wire bytes.
struct ANCWireMapping {
    static func toWire(_ mode: ANCMode) -> UInt8 {
        switch mode {
        case .on: return 0x02
        case .transparency: return 0x04
        case .off: return 0x01
        }
    }

    static func fromWire(_ byte: UInt8) -> ANCMode? {
        switch byte {
        case 0x02: return .on
        case 0x04: return .transparency
        case 0x01: return .off
        default: return nil
        }
    }
}
