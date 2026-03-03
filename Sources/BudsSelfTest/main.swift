import Foundation
import BudsCore

func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("[FAIL] \(message)\n", stderr)
        exit(1)
    }
}

func findRepoRoot() -> URL {
    // Resolve from source location so this works regardless of CWD.
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fm = FileManager.default

    while dir.path != "/" {
        var isDir: ObjCBool = false
        let sources = dir.appendingPathComponent("Sources").path
        if fm.fileExists(atPath: sources, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
        dir.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

func assertNoPollingPrimitives() {
    let root = findRepoRoot()
    let sourcesDir = root.appendingPathComponent("Sources")
    let fm = FileManager.default

    let forbiddenNeedles: [String] = [
        "Timer.scheduledTimer",
        "DispatchSourceTimer",
        "Publishers.Timer",
        "Timer.publish",
        ".autoconnect()",
        "batteryPollTask",
        "ancPollTask",
        "startPollersIfConnected",
        "caseProbeTask",
        "startCaseProbe"
    ]

    guard let e = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
        assert(false, "No polling guard: failed to enumerate Sources/")
        return
    }

    for case let fileURL as URL in e {
        guard fileURL.pathExtension == "swift" else { continue }
        // Don't self-match the guard implementation.
        if fileURL.path.contains("/Sources/BudsSelfTest/") { continue }
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { continue }

        for needle in forbiddenNeedles where text.contains(needle) {
            let rel = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            assert(false, "No polling guard: found '\(needle)' in \(rel)")
        }
    }
}

assertNoPollingPrimitives()

// Protocol fixtures
assert(OPOProtocol.helloPacket() == [0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x00, 0x12], "HELLO packet mismatch")

let reg = OPOProtocol.registerPacket(token: [0x01, 0x02, 0x03, 0x04])
assert(Array(reg.suffix(4)) == [0x01, 0x02, 0x03, 0x04], "REGISTER token mismatch")

// Battery parse fixture (pair format observed on your buds):
// AA .. .. .. 06 81 25 .. .. .. <count> 01 <L> 02 <R> 03 <Case>
let bat = [UInt8]([
    0xAA, 0x0F, 0x00, 0x00, 0x06, 0x81, 0x25, 0x08, 0x00, 0x00,
    0x03, 0x01, 0x50, 0x02, 0x52, 0x03, 0x3C
])

let b = OPOParse.parseBattery(bat)
assert(b?.left == 80, "Battery left parse")
assert(b?.right == 82, "Battery right parse")
assert(b?.case == 60, "Battery case parse")
assert(b?.averageLR == 81, "Battery average LR")
assert(b?.totalWeightedPercent == 64, "Battery weighted total percent")

// ANC push fixture (CAT=0x04 SUB=0x02): parser returns raw last byte (may be non-classic)
let ancPush = [UInt8](arrayLiteral: 0xAA, 0x0B, 0x00, 0x00, 0x04, 0x02, 0x10, 0x04, 0x00, 0x03, 0x01, 0x01, 0x10)
assert(OPOParse.parseANCModeByte(ancPush) == 0x10, "ANC push returns raw last byte")

// EQ table parse fixture (from your capture): CAT=0x05 SUB=0x81 CMD=0x2B, ASCII CSV triplets.
let eq = [UInt8]([
    0xAA, 0x50, 0x00, 0x00, 0x05, 0x81, 0x2B, 0x49, 0x00, 0x00, 0x09,
    0x31, 0x2C, 0x31, 0x2C, 0x31, 0x31, 0x31, 0x2C, 0x31, 0x2C, 0x32, 0x2C, 0x31, 0x35, 0x35, 0x2C,
    0x31, 0x2C, 0x33, 0x2C, 0x31, 0x35, 0x35, 0x2C, 0x32, 0x2C, 0x31, 0x2C, 0x31, 0x31, 0x31, 0x2C,
    0x32, 0x2C, 0x32, 0x2C, 0x31, 0x35, 0x35, 0x2C, 0x32, 0x2C, 0x33, 0x2C, 0x31, 0x35, 0x35, 0x2C,
    0x33, 0x2C, 0x31, 0x2C, 0x31, 0x31, 0x31, 0x2C, 0x33, 0x2C, 0x32, 0x2C, 0x31, 0x30, 0x31, 0x2C,
    0x33, 0x2C, 0x33, 0x2C, 0x31, 0x30, 0x31
])

let e = OPOParse.parseEQ(eq)
assert(e != nil, "EQ parse non-nil")
assert(e?.presets.count == 3, "EQ presets count")
assert(e?.presets.first(where: { $0.id == 1 })?.bands.count == 3, "EQ preset 1 band count")
assert(e?.presets.first(where: { $0.id == 3 })?.bands.first(where: { $0.id == 2 })?.value == 101, "EQ preset 3 band 2 value")

print("[OK] BudsSelfTest passed")
