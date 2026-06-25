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

    var phase: Phase = .idle
    var authorization: String = ""
    var devices: [DiscoveredPeripheral] = []
    var connectedName: String?
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
    /// When on, the device list shows only peripherals the engine can decode (debug app shows all by
    /// default; scanning itself stays unfiltered so nothing is hidden from the live capture/stream).
    var supportedOnly: Bool = false

    private let logLimit = 500

    /// Where an external observer can watch this session live.
    var logPath: String { logger.url.path }
    var streamURL: String { "http://127.0.0.1:\(logger.server.port)/" }

    /// Devices to present, honoring the "supported only" filter.
    var visibleDevices: [DiscoveredPeripheral] {
        supportedOnly ? devices.filter { SupportedDevices.supports($0) } : devices
    }

    /// Whether the engine recognises this peripheral as one it can decode.
    func isSupported(_ device: DiscoveredPeripheral) -> Bool {
        SupportedDevices.supports(device)
    }

    func refreshAuthorization() {
        authorization = central.authorizationDescription
        logger.log("auth", ["value": authorization, "stream": streamURL, "file": logPath])
    }

    func startScan() {
        devices = []
        phase = .scanning
        logger.log("scan_start")
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            do {
                try await self.central.waitUntilReady()
            } catch {
                self.fail(error)
                return
            }
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
        }
    }

    func stopScan() {
        central.finishActiveStreams()
        scanTask?.cancel()
        if phase == .scanning { phase = .idle }
        logger.log("scan_stop")
    }

    func connect(to device: DiscoveredPeripheral) {
        scanTask?.cancel()
        central.finishActiveStreams()
        phase = .connecting
        // Clear sticky readout state so a reconnect doesn't show the previous device's last RR.
        latest = nil
        latestRRMillis = nil
        connectedName = device.name ?? device.id.uuidString
        logger.log("connecting", ["id": device.id.uuidString, "name": connectedName ?? NSNull()])
        observeConnectionState() // before connect, so the first transition isn't missed
        connectTask = Task { @MainActor in
            do {
                try await self.central.connect(matching: .id(device.id), timeout: 15)
                self.services = try await self.central.inventory(readValues: true)
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

    func disconnect() {
        connectTask?.cancel()
        connectionTask?.cancel()
        rawTask?.cancel()
        measureTask?.cancel()
        batteryTask?.cancel()
        rssiTask?.cancel()
        central.finishActiveStreams()
        central.disconnect()
        phase = .idle
        services = []
        latest = nil
        latestRRMillis = nil
        battery = nil
        deviceInfo = nil
        features = nil
        rssi = nil
        connectionState = nil
        connectedName = nil
        logger.log("disconnect")
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
                    if self.phase == .connected || self.phase == .connecting {
                        self.phase = .failed(reason ?? "disconnected")
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
        case .auto: return SupportedDevices.parser(forServiceUUIDs: services.map(\.uuid))
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
                try? await Task.sleep(for: .seconds(3))
            }
        }

        Task { @MainActor in
            do {
                try await self.central.subscribe(characteristics: nil)
            } catch {
                self.fail(error)
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
