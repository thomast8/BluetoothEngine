import CoreBluetooth
import Foundation

/// A peripheral the engine has confirmed it can decode, plus *how* it was confirmed and *which*
/// decoder matched. The two confirmation levels mirror the two observation points:
/// - `.advertised` — the scan packet advertised a service we decode. Cheap (no connection), but a
///   best-effort signal: most devices don't advertise their primary service, so absence of this is
///   never proof of "unsupported".
/// - `.probed` — we connected, read the GATT inventory, and matched a parser by service *or*
///   characteristic. Authoritative: this is the only way to recognise a device whose advertisement
///   omitted its pulse-ox / heart-rate service.
public struct SupportedDevice: Sendable, Equatable {
    public enum Confirmation: Sendable, Equatable {
        case advertised
        case probed
        /// Already connected (to this app or the system) and known to expose a supported service — so
        /// it won't appear in a scan (a connected peripheral stops advertising), but is still usable.
        case connected

        /// Short label for display/logging.
        public var label: String {
            switch self {
            case .advertised: return "advertised"
            case .probed: return "probed"
            case .connected: return "connected"
            }
        }
    }

    public let peripheral: DiscoveredPeripheral
    public let confirmation: Confirmation
    /// The matching parser's concrete type name (e.g. `"PLXSParser"`), for display/logging. A name
    /// rather than the parser itself so the value stays `Equatable`/`Sendable`.
    public let decoderName: String

    public init(peripheral: DiscoveredPeripheral, confirmation: Confirmation, decoderName: String) {
        self.peripheral = peripheral
        self.confirmation = confirmation
        self.decoderName = decoderName
    }
}

/// The slice of `BLECentral` that `discoverSupported` needs. Pulling it behind a protocol keeps the
/// probing *policy* (which devices to probe, how to classify them) unit-testable with a fake, with no
/// CoreBluetooth or hardware — the same transport/decode seam the rest of the engine uses. `BLECentral`
/// satisfies it as-is.
@MainActor
public protocol DeviceProbing: Sendable {
    func waitUntilReady() async throws
    func scan(filterServices: [CBUUID]?) -> AsyncStream<DiscoveredPeripheral>
    func finishActiveStreams()
    /// Peripherals already connected (to this app or the system) exposing any of `serviceUUIDs`, each
    /// tagged with the matched service(s) in `advertisedServices`. A connected peripheral doesn't
    /// advertise, so this is the only way discovery can surface it.
    func connectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [DiscoveredPeripheral]
    func connect(matching match: PeripheralMatch, timeout: TimeInterval) async throws
    func inventory(readValues: Bool) async throws -> [ServiceInfo]
    func disconnect()
}

extension BLECentral: DeviceProbing {}

/// Discover the devices the engine can decode, doing the confirmation work itself so an app can just
/// display the result and remember which to connect to. Support is judged structurally against the
/// parser registry (`SupportedDevices`), never by device name or model.
///
/// Two modes:
/// - **Advertised-only (default, `probe == false`)** — one continuous passive scan; a peripheral that
///   *advertises* a known service is yielded immediately as `.advertised`. Non-intrusive: it never
///   connects to anything. Dedicated biometric sensors (pulse oximeters, HR bands in broadcast mode)
///   advertise their service, so this catches them instantly without touching strangers' devices.
/// - **Probe-enabled (`probe == true`)** — additionally connects to connectable unknowns to read their
///   GATT and confirm support. This is the only way to recognise a device that *doesn't* advertise its
///   service, but it is intrusive: it reaches out to nearby devices and some demand pairing. Use it as
///   an explicit opt-in when a sensor stays silent.
///
/// Probe policy (when enabled), repeated until the consumer drops the stream so late arrivals are caught:
/// scan for `scanWindow` seconds (yielding advertised matches live and queueing connectable unknowns),
/// then probe AT MOST ONE queued unknown — connect (bounded by `probeTimeout`), read the GATT, match via
/// `SupportedDevices.parser(for:)`, then disconnect. One-per-cycle keeps scanning the priority so an
/// advertised device never waits behind a queue of probes; each unknown is probed at most once. Runs one
/// session at a time to match `BLECentral`'s single-peripheral design.
@MainActor
public func discoverSupported(
    using transport: DeviceProbing,
    probe: Bool = false,
    probeTimeout: TimeInterval = 6,
    scanWindow: TimeInterval = 4
) -> AsyncStream<SupportedDevice> {
    AsyncStream { continuation in
        let task = Task { @MainActor in
            do {
                try await transport.waitUntilReady()
            } catch {
                continuation.finish()
                return
            }

            var resolved = Set<UUID>() // already yielded — never repeat

            // Surface already-connected supported peripherals first. They don't advertise (so no scan
            // would find them), but the system still knows them by their discovered services — this is
            // what makes a device that's already connected, including a link leaked from a prior run,
            // visible and reconnectable rather than "lost until power-cycled".
            for device in transport.connectedPeripherals(withServices: SupportedDevices.serviceUUIDs)
            where !resolved.contains(device.id) {
                if let parser = SupportedDevices.parser(forServiceUUIDs: device.advertisedServices) {
                    resolved.insert(device.id)
                    continuation.yield(SupportedDevice(
                        peripheral: device,
                        confirmation: .connected,
                        decoderName: String(describing: type(of: parser))
                    ))
                }
            }

            // Advertised-only (default): one continuous passive scan, yield matches as they arrive,
            // never connect to anything.
            guard probe else {
                let scan = transport.scan(filterServices: nil)
                for await device in scan where !resolved.contains(device.id) {
                    if let parser = SupportedDevices.parser(forServiceUUIDs: device.advertisedServices) {
                        resolved.insert(device.id)
                        continuation.yield(SupportedDevice(
                            peripheral: device,
                            confirmation: .advertised,
                            decoderName: String(describing: type(of: parser))
                        ))
                    }
                }
                continuation.finish()
                return
            }

            var probed = Set<UUID>()                        // probe attempted — never retry (bounds cost)
            var pending: [UUID: DiscoveredPeripheral] = [:] // connectable unknowns awaiting a probe

            while !Task.isCancelled {
                // Phase 1 — scan window. Surface advertised matches *immediately* and enqueue connectable
                // unknowns. Iterate inline (no second task touches the shared sets, so there's no
                // data race); a stopper ends the window by finishing the scan stream, which makes this
                // `for await` return.
                let scan = transport.scan(filterServices: nil)
                let stopper = Task { @MainActor in
                    // End the window by finishing the scan stream. If cancelled (we're tearing down),
                    // bail *without* finishing — otherwise a stale stopper could end a later scan window.
                    do { try await Task.sleep(for: .seconds(scanWindow)) } catch { return }
                    transport.finishActiveStreams()
                }
                for await device in scan {
                    guard !resolved.contains(device.id) else { continue }
                    if let parser = SupportedDevices.parser(forServiceUUIDs: device.advertisedServices) {
                        resolved.insert(device.id)
                        pending.removeValue(forKey: device.id)
                        continuation.yield(SupportedDevice(
                            peripheral: device,
                            confirmation: .advertised,
                            decoderName: String(describing: type(of: parser))
                        ))
                    } else if device.isConnectable, !probed.contains(device.id) {
                        pending[device.id] = device
                    }
                }
                stopper.cancel()
                if Task.isCancelled { break }

                // Phase 2 — probe AT MOST ONE pending unknown, then loop back to scanning. Probing pauses
                // the scan (single-session radio), so draining the whole queue at once would starve the
                // scan and badly delay an advertised device that appears meanwhile (e.g. a band that only
                // advertises every few seconds). One-per-cycle keeps scanning the priority; the queue
                // drains gradually across cycles, and once every unknown is probed it's pure scanning.
                guard let id = pending.keys.first(where: { !resolved.contains($0) }) else { continue }
                let device = pending.removeValue(forKey: id)!
                probed.insert(id)
                do {
                    try await transport.connect(matching: .id(id), timeout: probeTimeout)
                    let services = try await transport.inventory(readValues: false)
                    if let parser = SupportedDevices.parser(for: services) {
                        resolved.insert(id)
                        continuation.yield(SupportedDevice(
                            peripheral: device,
                            confirmation: .probed,
                            decoderName: String(describing: type(of: parser))
                        ))
                    }
                } catch {
                    // Unreachable / timed-out / inventory failure: leave it marked probed and move on.
                }
                transport.disconnect()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            // Just cancel: AsyncStream cancellation ends the scan loop, and dropping the scan stream
            // stops scanning. Crucially do NOT disconnect — discovery may be running while the app is
            // connected to a device (a re-scan), and a disconnect here would drop that live link.
            task.cancel()
        }
    }
}
