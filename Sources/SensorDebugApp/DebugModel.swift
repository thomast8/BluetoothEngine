import BluetoothEngine
import Foundation
import Observation

/// Drives a `BLECentral` for the debug GUI: scan → connect → inventory → live raw hex + decoded
/// measurements. All state is `@Observable` for SwiftUI; everything stays on the main actor. Every
/// event is also fanned out through `SessionLogger` (live SSE stream + JSONL file) so an external
/// observer sees exactly what the GUI sees.
@MainActor
@Observable
final class DebugModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case connecting
        case connected
        case failed(String)
    }

    enum ParserChoice: String, CaseIterable, Identifiable {
        case auto, plxs, hrs, proprietary
        var id: String { rawValue }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let monotonic: Double
        let characteristic: String
        let hex: String
    }

    private let central = BLECentral()
    private let logger = SessionLogger()
    private var scanTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var rawTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var rssiTask: Task<Void, Never>?
    private var subscribeTask: Task<Void, Never>?

    var phase: Phase = .idle
    var authorization: String = ""
    var devices: [DiscoveredPeripheral] = []
    var connectedName: String?
    /// The device we're currently connected to (or connecting to). Kept so the picker can keep showing
    /// it across a re-scan — a connected peripheral doesn't advertise, so a scan won't rediscover it.
    var connectedDevice: DiscoveredPeripheral?
    var services: [ServiceInfo] = []
    var latest: VitalsMeasurement?
    /// Last RR-interval set seen. Heart-rate frames carry RR only sporadically, so hold the previous
    /// value rather than blanking the readout on every plain (RR-less) HR frame.
    var latestRRMillis: [Double]?
    // Read-once + streamed device telemetry alongside the measurement readout.
    var battery: Int?
    var deviceInfo: DeviceInfo?
    var features: PLXFeatures?
    var rssi: Int?
    var connectionState: ConnectionState?
    var log: [LogLine] = []
    var parserChoice: ParserChoice = .auto
    /// Engine-confirmed devices (advertised match or probe-confirmed), shown by default. The stack does
    /// the probing — the app just displays the result and remembers which to connect to. See
    /// `discoverSupported`.
    var supportedDevices: [SupportedDevice] = []
    /// When on, the picker shows the raw passive scan (every BLE device) instead of the confirmed list —
    /// an escape hatch for reverse-engineering a device the engine doesn't decode yet.
    var showAllPassive: Bool = false
    /// When on (confirmed mode only), discovery also probes connectable unknowns to confirm support —
    /// intrusive (connects to nearby devices, can trigger pairing prompts), so off by default. Dedicated
    /// sensors advertise their service and are found without this.
    var probeUnknowns: Bool = false
    /// Decoder confirmed for the connected device (matched against its GATT), shown in the status line.
    var connectedDecoder: String?
    /// True when connected but streaming is quiet (no measurement for several seconds) — e.g. a band
    /// whose broadcast is off, or one we connected to before it started sending. The link is up; it's
    /// just not sending data.
    var dataStale: Bool = false
    private var lastMeasurementAt: Date?
    private var connectedSince: Date?
    private var connectStartedAt: Date?
    /// Ignore a switch to a different device within this window of starting a connect, to absorb a rapid
    /// click-storm. Rapid connect→cancel→connect churn wedges fragile devices (cheap oximeters); after
    /// the window a switch still supersedes, so a slow/hung connect can be abandoned.
    private let connectDebounce: TimeInterval = 1.0

    private let logLimit = 500

    /// Where an external observer can watch this session live.
    var logPath: String { logger.url.path }
    var streamURL: String { "http://127.0.0.1:\(logger.server.port)/" }

    /// Devices to present: the engine-confirmed list by default, or the raw passive scan when
    /// `showAllPassive` is on.
    var visibleDevices: [DiscoveredPeripheral] {
        showAllPassive ? devices : supportedDevices.map(\.peripheral)
    }

    /// The engine's confirmation for a device in the list (advertised vs probed, and which decoder),
    /// or nil if it isn't a confirmed device.
    func supportInfo(for id: UUID) -> SupportedDevice? {
        supportedDevices.first { $0.peripheral.id == id }
    }

    /// Advertised-only hint for the passive list — best-effort; connect to confirm.
    func isSupported(_ device: DiscoveredPeripheral) -> Bool {
        SupportedDevices.supports(device)
    }

    func refreshAuthorization() {
        authorization = central.authorizationDescription
        logger.log("auth", ["value": authorization, "stream": streamURL, "file": logPath])
    }

    func startScan() {
        // Don't start a scan while a connect is in flight — on the single-session radio a scan competes
        // with the connect and can disrupt a fragile device mid-connection. (Re-scanning once connected
        // is fine and is how an already-connected device stays in the list.)
        if phase == .connecting {
            logger.log("scan_ignored", ["reason": "connect in flight"])
            return
        }
        // Keep the currently-connected device in the list — a scan won't rediscover a connected
        // peripheral (it stops advertising), and dropping it would make switching back impossible.
        devices = devices.filter { $0.id == connectedDevice?.id }
        supportedDevices = supportedDevices.filter { $0.peripheral.id == connectedDevice?.id }
        phase = .scanning
        logger.log("scan_start", ["mode": showAllPassive ? "passive" : "discover"])
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            do {
                try await self.central.waitUntilReady()
            } catch {
                self.fail(error)
                return
            }
            if self.showAllPassive {
                // Passive: list every BLE device (for reverse-engineering an unsupported one).
                for await device in self.central.scan() {
                    if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                        self.devices[index] = device
                    } else {
                        self.devices.append(device)
                        self.logger.log("device", [
                            "id": device.id.uuidString,
                            "name": device.name ?? NSNull(),
                            "rssi": device.rssi,
                            "services": device.advertisedServices,
                            "connectable": device.isConnectable,
                            "supported": SupportedDevices.supports(device),
                        ])
                    }
                }
            } else {
                // Confirmed: the engine surfaces only what it can decode. Advertised-only unless the
                // user opts into probing connectable unknowns.
                for await found in discoverSupported(using: self.central, probe: self.probeUnknowns) {
                    if let index = self.supportedDevices.firstIndex(where: { $0.peripheral.id == found.peripheral.id }) {
                        self.supportedDevices[index] = found
                    } else {
                        self.supportedDevices.append(found)
                        self.logger.log("supported_device", [
                            "id": found.peripheral.id.uuidString,
                            "name": found.peripheral.name ?? NSNull(),
                            "rssi": found.peripheral.rssi,
                            "via": found.confirmation.label,
                            "decoder": found.decoderName,
                        ])
                    }
                }
            }
        }
    }

    func stopScan() {
        central.finishActiveStreams()
        scanTask?.cancel()
        if phase == .scanning { phase = .idle }
        logger.log("scan_stop")
    }

    func connect(to device: DiscoveredPeripheral) {
        // Already connected to this device — clicking it shouldn't tear down and reconnect (it's live,
        // shown with the connected badge). Switching to a *different* device falls through.
        if phase == .connected, connectedDevice?.id == device.id { return }
        // Debounce a click-storm: while a connect to a different device is still settling (started within
        // `connectDebounce`), ignore the switch so we don't churn connect→cancel→connect on a fragile
        // device. After the window the switch supersedes normally (a hung connect can still be abandoned).
        if phase == .connecting, let startedAt = connectStartedAt, connectedDevice?.id != device.id,
           Date().timeIntervalSince(startedAt) < connectDebounce {
            logger.log("connect_debounced", ["id": device.id.uuidString, "name": device.name ?? NSNull()])
            return
        }
        connectStartedAt = Date()
        // Tear down any current session first — the central is single-session, so switching devices
        // must not leave the previous device's connect/inventory or notification streams running
        // (the engine drops the previous peripheral itself). Cancel old tasks and clear stale readout.
        connectTask?.cancel()
        connectionTask?.cancel()
        rssiTask?.cancel()
        scanTask?.cancel()
        cancelStreamTasks()
        central.finishActiveStreams()
        phase = .connecting
        connectedDevice = device
        services = []
        log = [] // fresh notifications panel for the new connection (no stale frames from the last one)
        latest = nil
        latestRRMillis = nil
        lastMeasurementAt = nil
        connectedSince = nil
        dataStale = false
        connectedDecoder = nil
        battery = nil
        deviceInfo = nil
        features = nil
        rssi = nil
        connectedName = device.name ?? device.id.uuidString
        logger.log("connecting", ["id": device.id.uuidString, "name": connectedName ?? NSNull()])
        observeConnectionState() // before connect, so the first transition isn't missed
        connectTask = Task { @MainActor in
            do {
                try await self.central.connect(matching: .id(device.id), timeout: 15)
                self.services = try await self.central.inventory(readValues: true)
                // Authoritative decodability verdict from the real GATT (service OR characteristic).
                self.connectedDecoder = SupportedDevices.parser(for: self.services)
                    .map { String(describing: type(of: $0)) }
                self.connectedSince = Date()
                self.phase = .connected
                self.logger.log("connected", ["name": self.connectedName ?? NSNull()])
                self.logger.log("gatt", ["services": self.gattJSON()])
                await self.readTelemetry()
                self.startStreaming()
            } catch {
                // A user-initiated disconnect mid-connect cancels this task; don't flash `.failed`
                // over the `.idle` that `disconnect()` already set.
                if !Task.isCancelled { self.fail(error) }
            }
        }
    }

    /// Cancel the notification-stream consumer tasks (raw hex, measurements, battery, subscribe). Shared
    /// by every teardown path (connect/disconnect/unexpected-drop) so a new stream task can't be forgotten
    /// in one of them.
    private func cancelStreamTasks() {
        rawTask?.cancel()
        measureTask?.cancel()
        batteryTask?.cancel()
        subscribeTask?.cancel()
    }

    func disconnect() {
        connectTask?.cancel()
        connectionTask?.cancel()
        rssiTask?.cancel()
        cancelStreamTasks()
        central.finishActiveStreams()
        central.disconnect()
        phase = .idle
        services = []
        latest = nil
        latestRRMillis = nil
        lastMeasurementAt = nil
        connectedSince = nil
        dataStale = false
        battery = nil
        deviceInfo = nil
        features = nil
        rssi = nil
        connectionState = nil
        connectedName = nil
        connectedDevice = nil
        connectedDecoder = nil
        logger.log("disconnect")
    }

    /// The link dropped without a user-initiated disconnect (device powered off, out of range, or it
    /// stopped broadcasting and the link timed out). Clear the connection so the UI stops showing
    /// "connected"/pinning a device that's gone, and drop it from the list (a re-scan re-adds it if it
    /// returns). Stays out of `disconnect()` so a user disconnect doesn't double-run this.
    private func handleUnexpectedDisconnect() {
        cancelStreamTasks()
        if let goneID = connectedDevice?.id {
            supportedDevices.removeAll { $0.peripheral.id == goneID }
            devices.removeAll { $0.id == goneID }
        }
        connectedDevice = nil
        connectedDecoder = nil
        latest = nil
        latestRRMillis = nil
        lastMeasurementAt = nil
        connectedSince = nil
        dataStale = false
    }

    /// Mirror the engine's link lifecycle into `phase`, so an unexpected drop is reflected in the UI.
    /// (Cancelled in `disconnect` before we cancel the link, so a user-initiated disconnect doesn't
    /// flash a spurious "failed".)
    private func observeConnectionState() {
        let states = central.connectionStates()
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            for await state in states {
                self.connectionState = state
                self.logger.log("connection", ["state": Self.describe(state)])
                if case .disconnected(let reason) = state {
                    // Stop the RSSI poll loop (it isn't stream-backed, so it won't self-terminate the
                    // way the measurement/battery tasks do when the notification streams finish).
                    self.rssiTask?.cancel()
                    // Only an *established* connection dropping is a failure here; a connect attempt's own
                    // errors surface where `connect()` is awaited. This keeps a stale disconnect (e.g. a
                    // probe being torn down) from flashing "failed" over an in-progress connect.
                    if self.phase == .connected {
                        self.phase = .failed(reason ?? "disconnected")
                        self.handleUnexpectedDisconnect()
                    }
                }
            }
        }
    }

    /// Read-once telemetry on connect: device identity, capabilities, battery, and link RSSI.
    private func readTelemetry() async {
        let info = (try? await central.readDeviceInfo()) ?? DeviceInfo()
        deviceInfo = info.isEmpty ? nil : info
        features = (try? await central.readPLXFeatures()) ?? nil
        battery = (try? await central.readBatteryLevel()) ?? nil
        rssi = await central.readRSSI()
        let infoFields: [String: Any] = [
            "manufacturer": info.manufacturerName ?? NSNull(),
            "model": info.modelNumber ?? NSNull(),
            "serial": info.serialNumber ?? NSNull(),
            "firmware": info.firmwareRevision ?? NSNull(),
            "hardware": info.hardwareRevision ?? NSNull(),
            "software": info.softwareRevision ?? NSNull(),
        ]
        logger.log("device_info", infoFields)
        logger.log("plx_features", ["value": features?.shortDescription ?? NSNull(), "raw": features.map { Int($0.raw) } ?? NSNull()])
        logger.log("battery", ["level": battery ?? NSNull()])
        logger.log("rssi", ["dbm": rssi ?? NSNull()])
    }

    private static func describe(_ state: ConnectionState) -> String {
        switch state {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected(let reason): return reason.map { "disconnected: \($0)" } ?? "disconnected"
        }
    }

    func clearLog() {
        log = []
    }

    private func fail(_ error: Error) {
        let message = (error as? BLEError)?.description ?? "\(error)"
        phase = .failed(message)
        logger.log("error", ["message": message])
    }

    /// Returns the decoder for the current selection, or nil if `auto` finds no supported parser for
    /// the connected device (rather than silently falling back to a no-op stub).
    private func makeParser() -> MeasurementParser? {
        switch parserChoice {
        case .plxs: return PLXSParser()
        case .hrs: return HeartRateParser()
        case .proprietary: return ProprietaryPM100Parser()
        case .auto: return SupportedDevices.parser(for: services)
        }
    }

    private func startStreaming() {
        let rawStream = central.notifications()
        rawTask = Task { @MainActor in
            for await note in rawStream {
                let hex = Self.hex(note.data)
                self.log.append(LogLine(monotonic: note.monotonicSeconds, characteristic: note.characteristicUUID, hex: hex))
                if self.log.count > self.logLimit {
                    self.log.removeFirst(self.log.count - self.logLimit)
                }
                self.logger.log("notify", [
                    "t": note.monotonicSeconds,
                    "char": note.characteristicUUID,
                    "len": note.data.count,
                    "hex": hex,
                ])
            }
        }

        if let parser = makeParser() {
            logger.log("parser", ["choice": parserChoice.rawValue, "type": "\(type(of: parser))"])
            if parser is ProprietaryPM100Parser {
                // Stub decoder: surface that it produces nothing, so a quiet measurement panel reads
                // as "not implemented yet" rather than "device sent no data".
                logger.log("parser_unimplemented", [
                    "choice": parserChoice.rawValue,
                    "note": "proprietary PM100 decoder is a stub — no measurements will be produced",
                ])
            }
            let measureStream = vitalsMeasurements(from: central.notifications(), parser: parser)
            measureTask = Task { @MainActor in
                for await measurement in measureStream {
                    self.latest = measurement
                    self.lastMeasurementAt = Date()
                    self.dataStale = false
                    if let rr = measurement.rrIntervalsMillis { self.latestRRMillis = rr }
                    self.logger.log("measurement", [
                        "spo2": measurement.spo2 ?? NSNull(),
                        "pr": measurement.pulseRate ?? NSNull(),
                        "rr": measurement.rrIntervalsMillis ?? NSNull(),
                        "finger": measurement.contactDetected,
                        "quality": measurement.quality.rawValue,
                        "hex": Self.hex(measurement.raw),
                    ])
                }
            }
        } else {
            // `auto` found no decoder for this device — stream raw frames only, don't fake measurements.
            logger.log("no_decoder", ["choice": parserChoice.rawValue])
        }

        // Battery change notifications ride the same fan-out (subscribe(nil) below enables 0x2A19).
        let batteryStream = batteryLevels(from: central.notifications())
        batteryTask = Task { @MainActor in
            for await level in batteryStream {
                self.battery = level
                self.logger.log("battery", ["level": level])
            }
        }

        // Poll link RSSI for a live signal-strength readout (the engine exposes a one-shot read).
        rssiTask = Task { @MainActor in
            while !Task.isCancelled {
                if let value = await self.central.readRSSI() {
                    self.rssi = value
                    self.logger.log("rssi", ["dbm": value])
                }
                // Flag "connected but silent": no measurement for several seconds. Measured from the last
                // frame, or from connect time if none has arrived yet — so a device connected with its
                // broadcast off reads "no data" rather than a misleading all-clear.
                let since = self.lastMeasurementAt ?? self.connectedSince
                self.dataStale = since.map { Date().timeIntervalSince($0) > 5 } ?? false
                try? await Task.sleep(for: .seconds(3))
            }
        }

        subscribeTask = Task { @MainActor in
            do {
                try await self.central.subscribe(characteristics: nil)
            } catch {
                // A switch/disconnect tears this down — don't flash "failed" over the new session.
                if !Task.isCancelled { self.fail(error) }
            }
        }
    }

    private func gattJSON() -> [[String: Any]] {
        services.map { service in
            [
                "uuid": service.uuid,
                "name": service.knownName ?? NSNull(),
                "chars": service.characteristics.map { ch in
                    [
                        "uuid": ch.uuid,
                        "name": ch.knownName ?? NSNull(),
                        "props": ch.properties.shortDescription,
                        "valueHex": ch.value.map { Self.hex($0) } ?? NSNull(),
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
