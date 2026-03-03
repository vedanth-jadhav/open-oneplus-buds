import Foundation
@preconcurrency import CoreBluetooth
import OSLog

@MainActor
public protocol BudsClient: AnyObject {
    var events: AsyncStream<BudsEvent> { get }

    func start()
    func stop()

    /// Enable/disable live updates (notifications/telemetry).
    /// Disabling reduces earbud BLE traffic and battery impact.
    func setLiveUpdatesEnabled(_ enabled: Bool)

    func reconnectNow()
    func refreshAllNow(source: UpdateSource)

    func setANC(_ mode: ANCMode)
    func setEQPreset(_ preset: Int)
    func queryANC(source: UpdateSource)
    func queryBattery(source: UpdateSource)
    func queryDeviceInfo(source: UpdateSource)
    func queryEQ(source: UpdateSource)

    // Optional discovery tool (read-only). Not used by default UI.
    func scanEQCommands()
}

@MainActor
public final class BudsClientImpl: NSObject, BudsClient {

    public var events: AsyncStream<BudsEvent> { eventStream }

    private let eventStream: AsyncStream<BudsEvent>
    private let eventCont: AsyncStream<BudsEvent>.Continuation

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private var write079A: CBCharacteristic?
    private var notify079A: CBCharacteristic?
    private var notifyChars: [CBCharacteristic] = []
    private var liveUpdatesEnabled: Bool = false
    private var liveRxStartedAt: Date?
    private var liveRxPackets: Int = 0
    private var liveRxBytes: Int = 0

    private var connectionState: ConnectionState = .idle {
        didSet { emit(.connection(connectionState)) }
    }

    private var ancMode: ANCMode? {
        didSet {
            if let m = ancMode { emit(.anc(m, source: .device)) }
        }
    }

    private var battery: BatteryStatus? {
        didSet {
            if let b = battery { emit(.battery(b, source: .device)) }
        }
    }

    private var deviceInfo: DeviceInfo? {
        didSet {
            if let i = deviceInfo { emit(.deviceInfo(i)) }
        }
    }

    private var eqStatus: EQStatus? {
        didSet {
            if let e = eqStatus { emit(.eq(e)) }
        }
    }

    private var authState: AuthState = .notAuthenticated
    private var lastAuthAt: Date?

    // ANC state is push-driven (no periodic polling).

    private enum AuthState {
        case notAuthenticated
        case authenticating
        case authenticated
    }

    private var opQueue: [QueuedOperation] = []
    private var opRunning = false
    private var currentOpId: UUID?
    private var currentOpKind: OperationKind?
    private var currentDrainTask: Task<Void, Never>?
    private var currentOpWorkTask: Task<Void, Error>?

    private struct QueuedOperation {
        var kind: OperationKind
        var maxRetries: Int
        var timeout: Duration
        var run: @MainActor () async throws -> Void
    }

    private var reconnectTask: Task<Void, Never>?

    private var didInitialRefreshAfterConnect = false

    // Some devices send responses or telemetry unsolicited. We track a monotonically
    // increasing sequence for each model; query operations wait for the next update.
    private var batterySeq: UInt64 = 0
    private var deviceInfoSeq: UInt64 = 0
    private var eqSeq: UInt64 = 0
    private var ancSeq: UInt64 = 0

    private let debugEnabled = ProcessInfo.processInfo.environment["BUDS_DEBUG"] == "1"
    private let logger = Logger(subsystem: "local.nordbuds", category: "BudsClient")

    public override init() {
        var cont: AsyncStream<BudsEvent>.Continuation!
        self.eventStream = AsyncStream<BudsEvent> { c in
            cont = c
        }
        self.eventCont = cont

        super.init()
    }

    public func start() {
        guard central == nil else { return }
        connectionState = .idle
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func stop() {
        reconnectTask?.cancel(); reconnectTask = nil
        if let p = peripheral {
            // Best-effort: turn off notifications before disconnecting.
            for ch in notifyChars { p.setNotifyValue(false, for: ch) }
        }

        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        write079A = nil
        notify079A = nil
        notifyChars = []
        authState = .notAuthenticated
        central = nil
        ancMode = nil
        battery = nil
        deviceInfo = nil
        eqStatus = nil
        connectionState = .idle
    }

    public func setLiveUpdatesEnabled(_ enabled: Bool) {
        if debugEnabled { print("[LIVE] setLiveUpdatesEnabled(\(enabled ? "on" : "off"))") }
        if liveUpdatesEnabled != enabled {
            if enabled {
                liveRxStartedAt = Date()
                liveRxPackets = 0
                liveRxBytes = 0
                logger.info("LiveUpdates: on")
            } else if let start = liveRxStartedAt {
                let dt = max(0.001, Date().timeIntervalSince(start))
                let pps = Double(liveRxPackets) / dt
                let bps = Double(liveRxBytes) / dt
                logger.info("LiveUpdates: off after \(dt, privacy: .public)s (\(self.liveRxPackets, privacy: .public) pkts, \(self.liveRxBytes, privacy: .public) bytes, \(pps, privacy: .public) pkt/s, \(bps, privacy: .public) B/s)")
                liveRxStartedAt = nil
            }
        }
        liveUpdatesEnabled = enabled
        guard let p = peripheral else { return }
        for ch in notifyChars {
            p.setNotifyValue(enabled, for: ch)
        }

        // Some firmwares only start emitting vendor status/telemetry after the HELLO/REGISTER
        // handshake. Do this only on-demand (popover open), not as a periodic poll.
        if enabled, case .connected = connectionState {
            enqueue(kind: .authenticate, timeout: .seconds(8), maxRetries: 0) { [weak self] in
                guard let self else { return }
                try await self.ensureAuthenticated()
            }
        }
    }

    public func reconnectNow() {
        enqueue(kind: .reconnect, timeout: .seconds(15), maxRetries: 1) { [weak self] in
            guard let self else { return }
            self.connectionState = .reconnecting(name: self.peripheral?.name)
            self.authState = .notAuthenticated
            if let p = self.peripheral {
                self.central?.cancelPeripheralConnection(p)
            }
            self.peripheral = nil
            self.write079A = nil
            self.notify079A = nil
            self.notifyChars = []
            self.ancMode = nil
            self.startScanOrRetrieve()
        }
    }

    public func refreshAllNow(source: UpdateSource) {
        enqueue(kind: .refreshAll, timeout: .seconds(20), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            // Keep protocol traffic serialized and predictable. ANC/device/EQ are intentionally
            // not queried by default (ANC is push-driven; device/EQ removed from app UI).
            try await self.queryBatteryInternal(source: source)
        }
    }

    public func setANC(_ mode: ANCMode) {
        // User interaction should preempt any background refresh/query work.
        prioritizeUserANCChange()
        enqueueHighPriority(kind: .setANC, timeout: .seconds(18), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()

            // Match the original script's timing: QUERY then wait, then SET.
            self.emitOpStep("Querying ANC (preflight)")
            try? self.write079A(OPOProtocol.ancQueryPacket(), label: "ANC_QUERY")

            self.emitOpStep("Sending ANC: \(mode.rawValue)")
            // Gap between query and set (script uses ~1.5s).
            try await Task.sleep(for: .milliseconds(1500))
            let modeByte = ANCWireMapping.toWire(mode)
            try self.write079A(OPOProtocol.ancSetPacket(modeByte: modeByte), label: "ANC_SET(\(String(format: "%02X", modeByte)))")

            // Optimistically update UI; we'll attempt to re-query in the background.
            self.ancMode = mode
            self.ancSeq &+= 1
            self.emit(.anc(mode, source: .user))
        }
    }

    public func setEQPreset(_ preset: Int) {
        // EQ changes should also preempt any background refresh/query work.
        prioritizeUserEQChange()
        enqueueHighPriority(kind: .setEQPreset, timeout: .seconds(12), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()

            self.emitOpStep("Setting EQ preset: \(preset)")
            let p = UInt8(clamping: preset)
            try self.write079A(OPOProtocol.eqSetPresetPacket(preset: p), label: "EQ_SET_PRESET(\(preset))")

            // Best-effort: mark the selected preset locally; some firmwares do not expose
            // an "active preset" query.
            if var e = self.eqStatus {
                e.currentPreset = preset
                e.lastUpdated = Date()
                self.eqStatus = e
                self.emit(.eq(e))
            } else {
                let e = EQStatus(modeByte: nil, presets: [], currentPreset: preset, lastUpdated: Date())
                self.eqStatus = e
                self.emit(.eq(e))
            }

            // Refresh table in the background so UI can show band values if supported.
            // Intentionally no background query: keep traffic user-driven.
        }
    }

    public func queryANC(source: UpdateSource) {
        enqueue(kind: .queryANC, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryANCInternal(source: source)
        }
    }

    public func queryBattery(source: UpdateSource) {
        enqueue(kind: .queryBattery, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryBatteryInternal(source: source)
        }
    }

    public func queryDeviceInfo(source: UpdateSource) {
        enqueue(kind: .queryDeviceInfo, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryDeviceInfoInternal(source: source)
        }
    }

    public func queryEQ(source: UpdateSource) {
        enqueue(kind: .queryEQ, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryEQInternal(source: source)
        }
    }

    public func scanEQCommands() {
        enqueue(kind: .scanEQ, timeout: .seconds(25), maxRetries: 0) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            self.emitOpStep("Scanning EQ cmds")

            // Read-only queries; keeps risk low.
            // We don't currently use these results automatically; this is for discovery/debug.
            for cmd in UInt8(0x20)...UInt8(0x3F) {
                if Task.isCancelled { return }
                try? self.write079A(OPOProtocol.eqQueryPacket(cmd: cmd), label: "EQ_QUERY(cmd=\(String(format: "%02X", cmd)))")
                try? await Task.sleep(for: .milliseconds(320))
            }
        }
    }

    // MARK: - Queue

    private func enqueue(kind: OperationKind, timeout: Duration, maxRetries: Int, _ run: @escaping @MainActor () async throws -> Void) {
        opQueue.append(QueuedOperation(kind: kind, maxRetries: maxRetries, timeout: timeout, run: run))
        drainQueueIfNeeded()
    }

    private func enqueueHighPriority(kind: OperationKind, timeout: Duration, maxRetries: Int, _ run: @escaping @MainActor () async throws -> Void) {
        // Insert at the front so it runs next.
        opQueue.insert(QueuedOperation(kind: kind, maxRetries: maxRetries, timeout: timeout, run: run), at: 0)
        drainQueueIfNeeded()
    }

    private func prioritizeUserANCChange() {
        // When the user taps an ANC mode in the popover, we don't want background refreshes
        // (ANC/battery/etc queries) to "block" the control action. Cancel the current query and
        // drop any queued refresh/query work.
        let dropKinds: Set<OperationKind> = [.refreshAll, .queryANC, .queryBattery, .queryDeviceInfo, .queryEQ]
        opQueue.removeAll { dropKinds.contains($0.kind) || $0.kind == .setANC }

        if let runningKind = currentOpKind, dropKinds.contains(runningKind) || runningKind == .setANC {
            currentOpWorkTask?.cancel()
            currentDrainTask?.cancel()
        }
    }

    private func prioritizeUserEQChange() {
        let dropKinds: Set<OperationKind> = [.refreshAll, .queryANC, .queryBattery, .queryDeviceInfo, .queryEQ, .scanEQ]
        opQueue.removeAll { dropKinds.contains($0.kind) || $0.kind == .setEQPreset }

        if let runningKind = currentOpKind, dropKinds.contains(runningKind) || runningKind == .setEQPreset {
            currentOpWorkTask?.cancel()
            currentDrainTask?.cancel()
        }
    }

    private func drainQueueIfNeeded() {
        guard !opRunning else { return }
        guard !opQueue.isEmpty else { return }

        opRunning = true
        let op = opQueue.removeFirst()

        currentDrainTask?.cancel()
        currentDrainTask = Task { @MainActor in
            defer {
                self.opRunning = false
                self.currentOpId = nil
                self.currentOpKind = nil
                self.currentDrainTask = nil
                self.currentOpWorkTask = nil
                self.drainQueueIfNeeded()
            }

            let opId = UUID()
            self.currentOpId = opId
            self.currentOpKind = op.kind
            self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .queued)))

            var attempt = 0
            while true {
                attempt += 1
                do {
                    let work = Task { @MainActor in
                        self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .running(step: "Starting"))))
                        try await op.run()
                    }
                    self.currentOpWorkTask = work
                    defer { self.currentOpWorkTask = nil }

                    try await withTaskCancellationHandler {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await work.value }
                            group.addTask {
                                try await Task.sleep(for: op.timeout)
                                throw UserFacingError("Timed out")
                            }
                            _ = try await group.next()!
                            group.cancelAll()
                        }
                    } onCancel: {
                        work.cancel()
                    }

                    self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .succeeded)))
                    return
                } catch {
                    if error is CancellationError {
                        // Cancellation is used for user-priority operations and during reconnect/stop.
                        // Don't surface it as a failure in the UI.
                        self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .succeeded)))
                        return
                    }
                    let msg = (error as? UserFacingError)?.message ?? String(describing: error)
                    if attempt <= op.maxRetries + 1 {
                        self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .running(step: "Retrying (\(attempt-1))"))))
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .failed(message: msg))))
                    self.emit(.error(UserFacingError(msg)))
                    return
                }
            }
        }
    }

    // MARK: - BLE Helpers

    private func startScanOrRetrieve() {
        guard let central else { return }
        let retrieve = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: OPOProtocol.service079A)])
        if let first = retrieve.first {
            peripheral = first
            first.delegate = self
            connectionState = .connecting(name: first.name)
            central.connect(first, options: nil)
            return
        }

        connectionState = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func rememberNotifyChar(_ ch: CBCharacteristic) {
        if notifyChars.contains(where: { $0.uuid == ch.uuid }) { return }
        notifyChars.append(ch)
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(10)]
            var idx = 0

            while !Task.isCancelled {
                let wait = backoff[min(idx, backoff.count - 1)]
                idx += 1
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }

                if case .connected = self.connectionState {
                    return
                }

                self.startScanOrRetrieve()
            }
        }
    }

    private func write079APacket(_ bytes: [UInt8], label: String) async throws {
        try write079A(bytes, label: label)
    }

    private func write079A(_ bytes: [UInt8], label: String) throws {
        guard let p = peripheral, let ch = write079A else {
            throw UserFacingError("Not ready to send packets")
        }
        let data = Data(bytes)
        // Must be .withoutResponse per reverse-engineered behavior.
        p.writeValue(data, for: ch, type: .withoutResponse)
        let hex = OPOProtocol.hex(bytes)
        // Use info for important user-facing operations so it's easy to debug via `log stream`.
        let isInfo =
            label == "HELLO" ||
            label == "REGISTER" ||
            label == "BATTERY_QUERY" ||
            label == "INFO_QUERY" ||
            label == "EQ_QUERY" ||
            label.hasPrefix("EQ_SET_PRESET") ||
            label.hasPrefix("ANC_SET")

        if isInfo {
            logger.info("[TX] \(label, privacy: .public): \(hex, privacy: .public)")
        } else {
            logger.debug("[TX] \(label, privacy: .public): \(hex, privacy: .public)")
        }
        if debugEnabled { print("[TX] \(label): \(hex)") }
    }

    private func pokeReadNotify079A(reason: String) {
        guard peripheral != nil, notify079A != nil else { return }
        // NOTE: we no longer auto-poke reads because it adds traffic and some firmwares
        // return non-vendor bytes on read, which can confuse debugging and waste energy.
        // Kept as a manual/debug hook only.
        if debugEnabled {
            print("[BLE] (skipped) poke read 0200079A (\(reason))")
        }
    }

    private func ensureAuthenticated() async throws {
        guard case .connected = connectionState else {
            throw UserFacingError("Not connected")
        }
        switch authState {
        case .authenticated:
            return
        case .authenticating:
            // Wait briefly; operations are serialized anyway.
            try await Task.sleep(for: .milliseconds(250))
            if authState == .authenticated { return }
        case .notAuthenticated:
            break
        }

        let hadConnectedUI: Bool = {
            if case .connected = self.connectionState { return true }
            return false
        }()

        authState = .authenticating
        if !hadConnectedUI {
            connectionState = .authenticating(name: peripheral?.name)
        }

        emitOpStep("HELLO")
        try write079A(OPOProtocol.helloPacket(), label: "HELLO")
        try await Task.sleep(for: .seconds(2))

        emitOpStep("REGISTER")
        try write079A(OPOProtocol.registerPacket(), label: "REGISTER")
        try await Task.sleep(for: .milliseconds(1500))

        authState = .authenticated
        lastAuthAt = Date()
        connectionState = .connected(name: peripheral?.name)
    }

    private func awaitANCQuery(source: UpdateSource, timeout: Duration) async throws -> ANCMode {
        emitOpStep("Querying ANC")
        let startSeq = ancSeq
        try write079A(OPOProtocol.ancQueryPacket(), label: "ANC_QUERY")
        // Do not return a stale cached mode if the query doesn't trigger any updates.
        // If we don't see a new ANC update, treat status as unavailable.
        try await waitForSeqChangeWithPokes(
            current: { self.ancSeq },
            from: startSeq,
            timeout: timeout,
            reason: "ANC_QUERY"
        )
        if let m = ancMode { return m }
        throw UserFacingError("ANC status unavailable")
    }

    private func queryANCInternal(source: UpdateSource) async throws {
        do {
            let timeout: Duration = {
                switch source {
                case .device, .onOpen:
                    return .seconds(6)
                case .user:
                    return .seconds(3)
                }
            }()
            let m = try await awaitANCQuery(source: source, timeout: timeout)
            ancMode = m
            emit(.anc(m, source: source))
        } catch {
            // Don't fail the whole refresh flow if ANC status isn't queryable.
        }
    }

    private func queryBatteryInternal(source: UpdateSource) async throws {
        emitOpStep("Querying battery")
        let startSeq = batterySeq
        try write079A(OPOProtocol.batteryQueryPacket(), label: "BATTERY_QUERY")
        try await waitForSeqChangeWithPokes(
            current: { self.batterySeq },
            from: startSeq,
            timeout: .seconds(5),
            reason: "BATTERY_QUERY"
        )

        if var b = battery {
            b.lastUpdated = Date()
            battery = b
            emit(.battery(b, source: source))
            return
        }
        throw UserFacingError("Battery response missing")
    }

    private func queryDeviceInfoInternal(source: UpdateSource) async throws {
        emitOpStep("Querying device info")
        let startSeq = deviceInfoSeq
        try write079A(OPOProtocol.deviceInfoQueryPacket(), label: "INFO_QUERY")
        try await waitForSeqChangeWithPokes(
            current: { self.deviceInfoSeq },
            from: startSeq,
            timeout: .seconds(5),
            reason: "INFO_QUERY"
        )

        if var i = deviceInfo {
            i.lastUpdated = Date()
            deviceInfo = i
            emit(.deviceInfo(i))
            return
        }
        throw UserFacingError("Device info response missing")
    }

    private func queryEQInternal(source: UpdateSource) async throws {
        emitOpStep("Querying EQ")
        let startSeq = eqSeq
        try write079A(OPOProtocol.eqQueryPacket(), label: "EQ_QUERY")
        try await waitForSeqChangeWithPokes(
            current: { self.eqSeq },
            from: startSeq,
            timeout: .seconds(5),
            reason: "EQ_QUERY"
        )

        if var e = eqStatus {
            e.lastUpdated = Date()
            eqStatus = e
            emit(.eq(e))
            return
        }
        throw UserFacingError("EQ response missing")
    }

    private func emitOpStep(_ step: String) {
        let id = currentOpId ?? UUID()
        let kind = currentOpKind ?? .refreshAll
        emit(.operation(OperationEvent(id: id, kind: kind, phase: .running(step: step))))
    }

    private func emit(_ event: BudsEvent) {
        eventCont.yield(event)
    }

    // Note: we intentionally don't use a generic "withTimeout" helper because we need
    // explicit cancellation of the active work task when a user-priority operation arrives.

    private func waitForSeqChange(current: @escaping @MainActor () -> UInt64, from: UInt64, timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        while current() == from {
            if Date() >= deadline {
                throw UserFacingError("Timed out")
            }
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    private func waitForSeqChangeWithPokes(
        current: @escaping @MainActor () -> UInt64,
        from: UInt64,
        timeout: Duration,
        reason: String
    ) async throws {
        // Backwards-compatible wrapper; "pokes" disabled (no extra BLE reads).
        _ = reason
        try await waitForSeqChange(current: current, from: from, timeout: timeout)
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate

// CoreBluetooth delegate protocols are not actor-isolated. We run the central
// manager on the main queue and treat this object as main-actor owned.
extension BudsClientImpl: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanOrRetrieve()
        case .poweredOff:
            connectionState = .bluetoothOff
        case .unauthorized:
            connectionState = .bluetoothUnauthorized
        case .unsupported:
            connectionState = .bluetoothUnsupported
        case .resetting:
            connectionState = .bluetoothResetting
        case .unknown:
            connectionState = .failed(message: "Bluetooth state unknown")
        default:
            connectionState = .failed(message: "Bluetooth unavailable")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        guard let name = peripheral.name else { return }
        if name.contains("Nord Buds") || name.contains("OnePlus") {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            connectionState = .connecting(name: name)
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .discovering(name: peripheral.name)
        authState = .notAuthenticated
        write079A = nil
        notify079A = nil
        notifyChars = []
        didInitialRefreshAfterConnect = false
        // New BLE session: drop stale cached state so UI doesn't show old modes as "current".
        ancMode = nil
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .failed(message: "Failed to connect")
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        authState = .notAuthenticated
        write079A = nil
        notify079A = nil
        notifyChars = []
        didInitialRefreshAfterConnect = false
        lastAuthAt = nil
        ancMode = nil

        connectionState = .reconnecting(name: peripheral.name)
        scheduleReconnect()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            let uuid = ch.uuid.uuidString.uppercased()
            let props = ch.properties
            let serviceUUID = service.uuid.uuidString.uppercased()
            let is079C = serviceUUID == "0000079C-D102-11E1-9B23-00025B00A5A5"

            if uuid == OPOProtocol.write079A {
                write079A = ch
            } else if uuid == OPOProtocol.notify079A {
                notify079A = ch
            }

            // We never do polling, so we rely on notifications for "live" updates.
            // Subscribe to all safe notify/indicate characteristics (excluding 079C, which can
            // require encryption and disconnect), but only enable them when live updates are on.
            if !is079C,
               (props.contains(.notify) || props.contains(.indicate)),
               !(props.contains(.notifyEncryptionRequired) || props.contains(.indicateEncryptionRequired)) {
                rememberNotifyChar(ch)
                peripheral.setNotifyValue(liveUpdatesEnabled, for: ch)
            }
        }

        // Only consider the session "ready" once we have both the write and notify paths.
        // If we start sending queries before 0200079A notifications are enabled, we can miss
        // the response and time out even though the buds replied.
        if write079A != nil, notify079A != nil {
            connectionState = .connected(name: peripheral.name)
            didInitialRefreshAfterConnect = true
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if debugEnabled {
            if let error {
                print("[BLE] Notify state error (\(characteristic.uuid.uuidString)): \(error)")
            } else {
                print("[BLE] Notify state ok (\(characteristic.uuid.uuidString)): isNotifying=\(characteristic.isNotifying ? "y" : "n")")
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        if liveUpdatesEnabled {
            liveRxPackets &+= 1
            liveRxBytes &+= bytes.count
        }
        let hex = OPOProtocol.hex(bytes)
        logger.debug("[RX] \(characteristic.uuid.uuidString, privacy: .public): \(hex, privacy: .public)")
        if debugEnabled { print("[RX] \(characteristic.uuid.uuidString): \(hex)") }

        // Battery (strict: CAT=0x06 SUB=0x81 CMD=0x25)
        if bytes.count >= 12, bytes[safe: 4] == 0x06, bytes[safe: 5] == 0x81, bytes[safe: 6] == 0x25 {
            if let b = OPOParse.parseBattery(bytes) {
                battery = b
                batterySeq &+= 1
                logger.info("Battery parsed L=\(b.left ?? -1, privacy: .public) R=\(b.right ?? -1, privacy: .public) Case=\(b.case ?? -1, privacy: .public)")
            }
            return
        }

        // Battery (telemetry embedded; used to opportunistically learn case % without polling)
        if let b = OPOParse.parseBatteryTelemetry(bytes) {
            // Plausibility gate: never allow telemetry to clobber clearly-real values with garbage.
            // If we already have strong L/R values, ignore huge deltas.
            if let cur = battery {
                if let cl = cur.left, let nl = b.left, abs(cl - nl) > 30 { return }
                if let cr = cur.right, let nr = b.right, abs(cr - nr) > 30 { return }
                if let cc = cur.case, let nc = b.case, abs(cc - nc) > 40 { return }
            }

            battery = b
            batterySeq &+= 1
            logger.info("Battery telemetry L=\(b.left ?? -1, privacy: .public) R=\(b.right ?? -1, privacy: .public) Case=\(b.case ?? -1, privacy: .public)")
        }

        // Device info
        if bytes.count >= 8, bytes[safe: 4] == 0x03, bytes[safe: 5] == 0x81 {
            if let i = OPOParse.parseDeviceInfo(bytes) {
                deviceInfo = i
                deviceInfoSeq &+= 1
            }
            return
        }

        // EQ
        if bytes.count >= 7, bytes[safe: 4] == 0x05 {
            if let e = OPOParse.parseEQ(bytes) {
                // Preserve best-effort active preset across table refreshes; firmware often
                // doesn't include "current preset" in the EQ table response.
                var merged = e
                if merged.currentPreset == nil {
                    merged.currentPreset = eqStatus?.currentPreset
                }
                merged.lastUpdated = Date()
                eqStatus = merged
                eqSeq &+= 1
                if !merged.presets.isEmpty {
                    logger.info("EQ parsed presets=\(merged.presets.count, privacy: .public) current=\(merged.currentPreset ?? -1, privacy: .public)")
                }
            }
            return
        }

        // ANC (push frames)
        if let raw = OPOParse.parseANCModeByte(bytes) {
            let sub = bytes[safe: 5]

            // Query responses: wire bytes should map cleanly.
            if sub == 0x81, let m = ANCWireMapping.fromWire(raw) {
                if ancMode != m {
                    ancMode = m
                    ancSeq &+= 1
                }
                return
            }

            // 1) Push-status mapping (observed)
            if sub == 0x02 {
                let pushMode: ANCMode? = {
                    // Observed on your buds for ANC push-state frames (earbud long-press):
                    // - 0x10 = ANC On
                    // - 0x04 = Transparency
                    // - 0x01 = Off (typically only via phone/app)
                    switch raw {
                    case 0x10: return .on
                    case 0x04: return .transparency
                    case 0x01: return .off
                    default: return nil
                    }
                }()
                if let m = pushMode {
                    if ancMode != m {
                        ancMode = m
                        ancSeq &+= 1
                        if debugEnabled {
                            print("[ANC] Push state \(String(format: "%02X", raw)) -> \(m.rawValue)")
                        }
                    }
                    return
                }
            }
        }

        // Registration ack (script checks bytes[2] == 0x81). Not used for flow currently.
    }

    // Note: we intentionally do not attempt to "resolve" unknown ANC push bytes by querying,
    // because constant/background polling is undesirable. If the buds send unknown status
    // bytes, the app will reflect the last known mode until a known push state arrives.
}
