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
    private var rawTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?

    var phase: Phase = .idle
    var authorization: String = ""
    var devices: [DiscoveredPeripheral] = []
    var connectedName: String?
    var services: [ServiceInfo] = []
    var latest: VitalsMeasurement?
    /// Last RR-interval set seen. Heart-rate frames carry RR only sporadically, so hold the previous
    /// value rather than blanking the readout on every plain (RR-less) HR frame.
    var latestRRMillis: [Double]?
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
        Task { @MainActor in
            do {
                try await self.central.connect(matching: .id(device.id), timeout: 15)
                self.services = try await self.central.inventory(readValues: true)
                self.phase = .connected
                self.logger.log("connected", ["name": self.connectedName ?? NSNull()])
                self.logger.log("gatt", ["services": self.gattJSON()])
                self.startStreaming()
            } catch {
                self.fail(error)
            }
        }
    }

    func disconnect() {
        rawTask?.cancel()
        measureTask?.cancel()
        central.finishActiveStreams()
        central.disconnect()
        phase = .idle
        services = []
        latest = nil
        latestRRMillis = nil
        connectedName = nil
        logger.log("disconnect")
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
