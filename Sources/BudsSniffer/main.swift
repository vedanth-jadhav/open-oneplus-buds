import Foundation
import CoreBluetooth
import BudsCore

private extension Array {
    subscript(safe idx: Int) -> Element? {
        guard idx >= 0 && idx < count else { return nil }
        return self[idx]
    }
}

private struct Options {
    var nameSubstring: String?
    var noAuth: Bool = false
    var queryANC: Bool = false
    var queryBattery: Bool = false
    var queryInfo: Bool = false
    var queryEQ: Bool = false
    var setEQPreset: Int?
    var probeEQSet: Int?
    var eqSetCmd: UInt8?
    var eqSetFlag: UInt8?
    var setANC: ANCMode?
    var timeoutSeconds: TimeInterval = 0
    var listOnly: Bool = false
    var wideScan: Bool = true
    var allowDuplicates: Bool = false
    var unsafeAllNotify: Bool = false
    var readAllReadable: Bool = true
    var pokeReadNotify079A: Bool = false
    var writeWithResponse: Bool = false
    var enable079C: Bool = false
}

private func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--name":
            if i + 1 < args.count {
                o.nameSubstring = args[i + 1]
                i += 1
            }
        case "--no-auth":
            o.noAuth = true
        case "--query-anc":
            o.queryANC = true
        case "--query-battery":
            o.queryBattery = true
        case "--query-info":
            o.queryInfo = true
        case "--query-eq":
            o.queryEQ = true
        case "--set-eq-preset":
            if i + 1 < args.count, let v = Int(args[i + 1]) {
                o.setEQPreset = v
                i += 1
            }
        case "--probe-eq-set":
            if i + 1 < args.count, let v = Int(args[i + 1]) {
                o.probeEQSet = v
                i += 1
            }
        case "--eq-set-cmd":
            if i + 1 < args.count {
                let s = args[i + 1].lowercased().replacingOccurrences(of: "0x", with: "")
                if let v = UInt8(s, radix: 16) { o.eqSetCmd = v }
                i += 1
            }
        case "--eq-set-flag":
            if i + 1 < args.count {
                let s = args[i + 1].lowercased().replacingOccurrences(of: "0x", with: "")
                if let v = UInt8(s, radix: 16) { o.eqSetFlag = v }
                i += 1
            }
        case "--scan-eq":
            // Alias for a light probe using queries only (no SET).
            o.queryEQ = true
        case "--set-anc":
            if i + 1 < args.count {
                let v = args[i + 1].lowercased()
                switch v {
                case "on": o.setANC = .on
                case "trans", "transparency": o.setANC = .transparency
                case "off": o.setANC = .off
                default: break
                }
                i += 1
            }
        case "--timeout":
            if i + 1 < args.count, let v = Double(args[i + 1]) {
                o.timeoutSeconds = v
                i += 1
            }
        case "--list":
            o.listOnly = true
        case "--no-wide-scan":
            o.wideScan = false
        case "--dupes":
            o.allowDuplicates = true
        case "--unsafe-all-notify":
            o.unsafeAllNotify = true
        case "--no-read":
            o.readAllReadable = false
        case "--poke-read":
            o.pokeReadNotify079A = true
        case "--with-response":
            o.writeWithResponse = true
        case "--enable-079c":
            o.enable079C = true
        case "--help", "-h":
            print("""
            BudsSniffer - listen to OnePlus/Nord Buds vendor notifications (079A + FE2C)

            Usage:
              swift run BudsSniffer -- [options]

            Options:
              --name <substring>   Filter peripherals by name substring
              --no-auth            Do not send HELLO/REGISTER
              --query-anc          After auth, send one ANC query packet
              --query-battery      After auth, send one battery query packet
              --query-info         After auth, send one device-info query packet
              --query-eq           After auth, send one EQ query packet
              --set-eq-preset <1..> After auth, send one EQ SET preset packet (experimental)
              --probe-eq-set <preset>  After auth, try a small set of EQ SET candidates and print any CAT=0x05 replies (experimental)
              --eq-set-cmd <hex>   Override EQ SET cmd byte (default: try 0x2C,0x2D,0x2B)
              --eq-set-flag <hex>  Override EQ SET flag byte (default: try 0x03 then 0x01)
              --set-anc <on|trans|off>  After auth, send one ANC SET packet
              --timeout <seconds>  Stop after N seconds (0 = run until Ctrl-C)
              --list               Only list discovered devices + adv data; do not connect
              --no-wide-scan       Do not fall back to scanning all devices
              --dupes              Allow duplicate advertisements (more spam, sometimes useful)
              --unsafe-all-notify  Subscribe to *all* notify/indicate characteristics (may disconnect some devices)
              --no-read            Do not issue readValue() for readable characteristics
              --poke-read          After queries, also read 0200079A once (helps diagnose devices that don't notify)
              --with-response      Use .withResponse for writes (diagnostic; app uses .withoutResponse)
              --enable-079c        Also attempt to subscribe/read 079C (may prompt pairing; may disconnect if encryption isn't available)
            """)
            exit(0)
        default:
            break
        }
        i += 1
    }
    return o
}

@MainActor
private final class Sniffer: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let options: Options
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    private var write079A: CBCharacteristic?
    private var notify079A: CBCharacteristic?
    private var didStart: Bool = false
    private var didScheduleAuth: Bool = false
    private var scanPhase: Int = 0
    private var didDiscoverAny: Bool = false
    private var widenTask: Task<Void, Never>?
    private var pendingReadUUIDs: Set<String> = []

    private let service079A = CBUUID(string: OPOProtocol.service079A)
    private let service079C = CBUUID(string: "0000079C-D102-11E1-9B23-00025B00A5A5")
    private let write079AUUID = CBUUID(string: OPOProtocol.write079A)
    private let notify079AUUID = CBUUID(string: OPOProtocol.notify079A)
    private let serviceFE2C = CBUUID(string: "FE2C")

    init(options: Options) {
        self.options = options
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        if options.timeoutSeconds > 0 {
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.options.timeoutSeconds * 1_000_000_000))
                self.log("Timeout reached, exiting")
                self.shutdown(exitCode: 0)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if !didStart {
                didStart = true
                startScan()
            }
        case .poweredOff:
            log("Bluetooth is OFF (turn it on in System Settings)")
        case .unauthorized:
            log("Bluetooth permission needed. System Settings -> Privacy & Security -> Bluetooth -> allow Terminal/BudsSniffer.")
        case .unsupported:
            log("Bluetooth unsupported on this Mac")
        case .resetting:
            log("Bluetooth resetting...")
        case .unknown:
            log("Bluetooth state unknown...")
        @unknown default:
            log("Bluetooth state: \(central.state.rawValue)")
        }
    }

    private func startScan() {
        // Phase 0: try a filtered scan for the vendor service (lowest noise).
        // Many earbuds do NOT advertise this service UUID, so we optionally fall back to a wide scan.
        scanPhase = 0
        didDiscoverAny = false
        widenTask?.cancel()
        widenTask = nil

        log("Scanning (phase 0: service filter 079A)...")
        central.scanForPeripherals(withServices: [service079A], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: options.allowDuplicates
        ])

        guard options.wideScan else { return }
        widenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            if self.peripheral != nil { return }
            if self.didDiscoverAny { return }
            self.log("No devices advertising 079A found. Falling back to wide scan...")
            self.central.stopScan()
            self.scanPhase = 1
            self.central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: self.options.allowDuplicates
            ])
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover p: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        didDiscoverAny = true
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "?"
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let uuidList = uuids.map(\.uuidString).joined(separator: ",")
        let advHint = uuidList.isEmpty ? "" : " svc=[\(uuidList)]"
        let isConn = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let connHint = (isConn == nil) ? "" : " conn=\(isConn! ? "y" : "n")"

        var extraHints: [String] = []
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let mb = [UInt8](mfg)
            if !mb.isEmpty {
                extraHints.append("mfg=\(OPOProtocol.hex(mb))")
            }
        }
        if let svcData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !svcData.isEmpty {
            let parts = svcData
                .sorted(by: { $0.key.uuidString < $1.key.uuidString })
                .map { "\($0.key.uuidString)=\(OPOProtocol.hex([UInt8]($0.value)))" }
            extraHints.append("svcData={\(parts.joined(separator: " "))}")
        }
        let extra = extraHints.isEmpty ? "" : " " + extraHints.joined(separator: " ")

        // Always print what we see; it helps pick a --name filter.
        log("Seen: \(name) (RSSI \(RSSI))\(advHint)\(connHint)\(extra)")

        if options.listOnly { return }

        // Connection selection logic:
        // - If user provided --name, connect to the first match.
        // - Otherwise, only auto-connect when the adv explicitly includes 079A.
        if let sub = options.nameSubstring {
            if !name.localizedCaseInsensitiveContains(sub) { return }
        } else {
            if !uuids.contains(service079A) { return }
        }

        log("Selected: \(name) -> connecting")
        self.peripheral = p
        central.stopScan()
        p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected: \(peripheral.name ?? "?") -> discovering services")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        shutdown(exitCode: 2)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        shutdown(exitCode: 0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery error: \(error.localizedDescription)")
            shutdown(exitCode: 3)
            return
        }
        let services = peripheral.services ?? []
        let svcList = services.map { $0.uuid.uuidString }.joined(separator: ",")
        log("Services: \(services.count) [\(svcList)] -> discovering characteristics")

        if !services.contains(where: { $0.uuid == service079A }) {
            log("Warning: connected device does not expose 079A service. If this isn't your buds, re-run with --name <substring> and/or --list.")
        }

        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("Characteristic discovery error: \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        for ch in chars {
            if !options.listOnly {
                let props = describeProps(ch.properties)
                log("Char: \(service.uuid.uuidString) / \(ch.uuid.uuidString) props=[\(props)]")
            }
            if ch.uuid == write079AUUID {
                write079A = ch
            }
            if ch.uuid == notify079AUUID {
                notify079A = ch
            }

            let props = ch.properties
            let wantsNotify: Bool = {
                if options.unsafeAllNotify {
                    return props.contains(.notify) || props.contains(.indicate) || ch.uuid == notify079AUUID
                }
                // Default mode: subscribe broadly, but skip 079C unless explicitly enabled (it can require encryption and cause disconnects).
                if service.uuid == service079C { return options.enable079C }
                if ch.uuid.uuidString.hasSuffix("079C-D102-11E1-9B23-00025B00A5A5") { return false }
                if ch.uuid == notify079AUUID { return true }
                return props.contains(.notify) || props.contains(.indicate)
            }()

            if wantsNotify {
                // Some characteristics will disconnect the device if we try to subscribe without encryption.
                // Skip anything that explicitly says encryption is required.
                if props.contains(.notifyEncryptionRequired) || props.contains(.indicateEncryptionRequired) {
                    if !options.listOnly {
                        log("Skip Notify (encryption required): \(ch.uuid.uuidString)")
                    }
                } else {
                    peripheral.setNotifyValue(true, for: ch)
                    if !options.listOnly {
                        log("Notify ON: \(ch.uuid.uuidString)")
                    }
                }
            }

            // Reads can be helpful, but some services (notably 079C) can misbehave without encryption
            // and may interfere with the session. Also, reading the vendor notify characteristic tends
            // to return non-protocol bytes (not the AA-framed responses we're looking for).
            if options.readAllReadable, props.contains(.read), (service.uuid != service079C || options.enable079C), ch.uuid != notify079AUUID {
                pendingReadUUIDs.insert(ch.uuid.uuidString.uppercased())
                peripheral.readValue(for: ch)
            }
        }

        // Once we have the write characteristic, schedule auth/query once.
        if write079A != nil {
            scheduleHelloRegisterAndOptionalQuery()
        }
    }

    private func describeProps(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.broadcast) { out.append("broadcast") }
        if p.contains(.read) { out.append("read") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoRsp") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        if p.contains(.authenticatedSignedWrites) { out.append("signed") }
        if p.contains(.extendedProperties) { out.append("ext") }
        if p.contains(.notifyEncryptionRequired) { out.append("notifyEnc") }
        if p.contains(.indicateEncryptionRequired) { out.append("indicateEnc") }
        return out.joined(separator: ",")
    }

    private func scheduleHelloRegisterAndOptionalQuery() {
        // Avoid scheduling multiple times (characteristics discovery can fire per service).
        if didScheduleAuth { return }
        didScheduleAuth = true

        guard let p = peripheral, let w = write079A else {
            log("Missing write characteristic 0100079A; cannot send HELLO/REGISTER/QUERY")
            return
        }

        if options.noAuth {
            log("Auth disabled (--no-auth). Listening only.")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Mirror the original script's pacing more closely.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.tx(p, w, label: "HELLO", bytes: OPOProtocol.helloPacket())

            // Many devices are picky about this delay. 2.0s matches the proven ANC flow.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.tx(p, w, label: "REGISTER", bytes: OPOProtocol.registerPacket())

            // Give device time to enter registered state before sending any query/set.
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            if self.options.queryBattery {
                self.tx(p, w, label: "BATTERY_QUERY", bytes: OPOProtocol.batteryQueryPacket())
            }
            if self.options.queryInfo {
                self.tx(p, w, label: "INFO_QUERY", bytes: OPOProtocol.deviceInfoQueryPacket())
            }
            if self.options.queryEQ {
                self.tx(p, w, label: "EQ_QUERY", bytes: OPOProtocol.eqQueryPacket())
            }

            if let preset = self.options.setEQPreset {
                let p8 = UInt8(clamping: preset)
                let cmd = self.options.eqSetCmd ?? 0x2B
                let flag = self.options.eqSetFlag ?? 0x03
                let pkt: [UInt8] = [0xAA, 0x0A, 0x00, 0x00, 0x05, 0x04, cmd, flag, 0x00, 0x01, 0x01, p8]
                self.tx(p, w, label: "EQ_SET_PRESET(cmd=\(String(format: "%02X", cmd)) flag=\(String(format: "%02X", flag)) p=\(preset))", bytes: pkt)
            }

            if let preset = self.options.probeEQSet {
                let p8 = UInt8(clamping: preset)
                let cmds: [UInt8] = self.options.eqSetCmd.map { [$0] } ?? [0x2C, 0x2D, 0x2B, 0x2E]
                let flags: [UInt8] = self.options.eqSetFlag.map { [$0] } ?? [0x03, 0x01, 0x00]
                for cmd in cmds {
                    for flag in flags {
                        let pkt: [UInt8] = [0xAA, 0x0A, 0x00, 0x00, 0x05, 0x04, cmd, flag, 0x00, 0x01, 0x01, p8]
                        self.tx(p, w, label: "EQ_SET_PROBE(cmd=\(String(format: "%02X", cmd)) flag=\(String(format: "%02X", flag)) p=\(preset))", bytes: pkt)
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        // Follow with a table query to see if anything changes or if a reply is triggered.
                        self.tx(p, w, label: "EQ_QUERY(2B)", bytes: OPOProtocol.eqQueryPacket())
                        try? await Task.sleep(nanoseconds: 900_000_000)
                    }
                }
            }
            if self.options.queryANC {
                self.tx(p, w, label: "ANC_QUERY", bytes: OPOProtocol.ancQueryPacket())
            }
            if let mode = self.options.setANC {
                let wire: UInt8
                switch mode {
                case .on: wire = 0x02
                case .transparency: wire = 0x04
                case .off: wire = 0x01
                }
                self.tx(p, w, label: "ANC_SET(\(mode.rawValue))", bytes: OPOProtocol.ancSetPacket(modeByte: wire))
            }

            if self.options.pokeReadNotify079A, let n = self.notify079A {
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.log("Poke read: \(n.uuid.uuidString)")
                self.pendingReadUUIDs.insert(n.uuid.uuidString.uppercased())
                p.readValue(for: n)
            }
        }
    }

    private func tx(_ p: CBPeripheral, _ w: CBCharacteristic, label: String, bytes: [UInt8]) {
        log("TX \(label) \(OPOProtocol.hex(bytes))")
        let t: CBCharacteristicWriteType = options.writeWithResponse ? .withResponse : .withoutResponse
        p.writeValue(Data(bytes), for: w, type: t)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("TX ack error (\(characteristic.uuid.uuidString)): \(error.localizedDescription)")
        } else {
            log("TX ack ok (\(characteristic.uuid.uuidString))")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Notify state error (\(characteristic.uuid.uuidString)): \(error.localizedDescription)")
        } else {
            log("Notify state ok (\(characteristic.uuid.uuidString)): isNotifying=\(characteristic.isNotifying ? "y" : "n")")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("RX error (\(characteristic.uuid.uuidString)): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)

        var flags: [String] = []
        let u = characteristic.uuid.uuidString.uppercased()
        if pendingReadUUIDs.remove(u) != nil {
            flags.append("src=read")
        } else {
            flags.append("src=notify")
        }

        // Loose ANC-ish heuristic for sniffing:
        // - Vendor protocol frames start with 0xAA.
        // - ANC category is usually bytes[4] == 0x04.
        // - Mode bytes we care about are 0x01/0x02/0x04.
        if bytes.count >= 8, bytes.first == 0xAA, bytes[safe: 4] == 0x04 {
            let tail: [UInt8] = [bytes.last ?? UInt8(0), bytes[bytes.count - 2]]
            if tail.contains(where: { $0 == 0x01 || $0 == 0x02 || $0 == 0x04 }) {
                flags.append("ANC-ish")
            }
            if bytes.count >= 6, bytes[5] == 0x02 {
                flags.append("ANC_PUSH(last=\(String(format: "%02X", bytes.last ?? 0)))")
            }
        }

        if let modeByte = OPOParse.parseANCModeByte(bytes) {
            let sub = bytes[safe: 5]
            let modeText: String
            if sub == 0x02 {
                // Push state mapping observed on your buds.
                switch modeByte {
                case 0x10: modeText = "on"
                case 0x04: modeText = "trans"
                default: modeText = "push=\(String(format: "%02X", modeByte))"
                }
            } else {
                // Query/response mapping (wire bytes).
                switch modeByte {
                case 0x04: modeText = "on"
                case 0x02: modeText = "trans"
                case 0x01: modeText = "off"
                default: modeText = "wire=\(String(format: "%02X", modeByte))"
                }
            }
            flags.append("ANC=\(modeText)")
            flags.append("ancByte=\(String(format: "%02X", modeByte))")
        }

        if let b = OPOParse.parseBattery(bytes) {
            flags.append("BAT L=\(b.left ?? -1) R=\(b.right ?? -1) C=\(b.case ?? -1)")
        }

        if let i = OPOParse.parseDeviceInfo(bytes) {
            flags.append("INFO status=\(i.statusByte ?? 0)")
        }

        if let e = OPOParse.parseEQ(bytes) {
            if !e.presets.isEmpty {
                flags.append("EQ presets=\(e.presets.count)")
                let ids = e.presets.map { $0.id }.sorted().map(String.init).joined(separator: ",")
                flags.append("EQ ids=[\(ids)]")
            } else {
                flags.append("EQ mode=\(e.modeByte ?? 0)")
            }
        }

        let suffix = flags.isEmpty ? "" : " [" + flags.joined(separator: " ") + "]"
        log("RX \(characteristic.uuid.uuidString) \(OPOProtocol.hex(bytes))\(suffix)")
    }

    private func log(_ s: String) {
        print("\(timestamp()) \(s)")
        fflush(stdout)
    }

    private func timestamp() -> String {
        let now = Date()
        let df = Sniffer.dateFormatter
        return df.string(from: now)
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    func shutdown(exitCode: Int32) {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        exit(exitCode)
    }
}

@main
struct BudsSnifferMain {
    static func main() {
        let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
        let sniffer = Sniffer(options: options)

        signal(SIGINT, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigSource.setEventHandler {
            sniffer.shutdown(exitCode: 0)
        }
        sigSource.resume()

        sniffer.start()
        RunLoop.main.run()
    }
}
