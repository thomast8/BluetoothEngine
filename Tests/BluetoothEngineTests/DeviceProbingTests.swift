import CoreBluetooth
import XCTest
@testable import BluetoothEngine

/// Exercises the `discoverSupported` probing *policy* against a fake transport — no CoreBluetooth, no
/// hardware. Proves the smart/bounded rules: advertised matches skip the probe, connectable unknowns
/// are probed once, non-connectable devices are skipped, and only structurally-decodable GATTs are
/// yielded. Nothing here references a device by name — support is judged purely from the registry.
///
/// `@MainActor` because the fake transport (like `BLECentral`) is main-actor-isolated, and the asserts
/// read its call-tracking state.
///
/// NOTE: this fake models the discovery *policy* only. `BLECentral`'s connection-management hardening
/// (scan/connect generation guards, reconnect-by-identifier, the `peripheral === peripheral` delegate
/// guards, supersede/switch races) depends on live CoreBluetooth and is NOT unit-covered here — it is
/// verified on real hardware (PM100 + Whoop). Don't assume these tests exercise that layer.
@MainActor
final class DeviceProbingTests: XCTestCase {
    // MARK: Fake transport

    @MainActor
    private final class FakeProbe: DeviceProbing {
        let advertisements: [DiscoveredPeripheral] // re-yielded on every scan() call
        let connected: [DiscoveredPeripheral] // already-connected, returned by connectedPeripherals(...)
        var gattByID: [UUID: [ServiceInfo]] // inventory result once connected
        var connectFailIDs: Set<UUID> // ids whose connect throws (unreachable)

        private(set) var connectCalls: [UUID] = []
        private(set) var inventoryCalls = 0
        private(set) var disconnectCalls = 0
        /// Ordered log of "scan"/"connect" actions, to assert one-per-cycle (a scan between probes).
        private(set) var actions: [String] = []

        private var scanContinuation: AsyncStream<DiscoveredPeripheral>.Continuation?
        private var connectedID: UUID?

        init(
            advertisements: [DiscoveredPeripheral],
            connected: [DiscoveredPeripheral] = [],
            gattByID: [UUID: [ServiceInfo]] = [:],
            connectFailIDs: Set<UUID> = []
        ) {
            self.advertisements = advertisements
            self.connected = connected
            self.gattByID = gattByID
            self.connectFailIDs = connectFailIDs
        }

        func waitUntilReady() async throws {}

        func scan(filterServices: [CBUUID]?) -> AsyncStream<DiscoveredPeripheral> {
            actions.append("scan")
            let (stream, cont) = AsyncStream<DiscoveredPeripheral>.makeStream()
            scanContinuation = cont
            for ad in advertisements { cont.yield(ad) }
            return stream
        }

        func finishActiveStreams() {
            scanContinuation?.finish()
            scanContinuation = nil
        }

        func connectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [DiscoveredPeripheral] {
            connected
        }

        func connect(matching match: PeripheralMatch, timeout: TimeInterval) async throws {
            guard case .id(let id) = match else {
                throw BLEError.deviceNotFound(query: match.description)
            }
            actions.append("connect")
            connectCalls.append(id)
            if connectFailIDs.contains(id) {
                throw BLEError.deviceNotFound(query: id.uuidString)
            }
            connectedID = id
        }

        func inventory(readValues: Bool) async throws -> [ServiceInfo] {
            inventoryCalls += 1
            guard let id = connectedID else { return [] }
            return gattByID[id] ?? []
        }

        func disconnect() {
            disconnectCalls += 1
            connectedID = nil
        }
    }

    // MARK: Fixtures

    private func device(advertised: [String], connectable: Bool) -> DiscoveredPeripheral {
        DiscoveredPeripheral(
            id: UUID(),
            name: "dev",
            rssi: -55,
            advertisedServices: advertised,
            isConnectable: connectable
        )
    }

    private func char(_ uuid: String) -> CharacteristicInfo {
        CharacteristicInfo(uuid: uuid, knownName: nil, propertiesRaw: 0x10, value: nil, descriptors: [])
    }

    private func plxsGATT() -> [ServiceInfo] {
        [ServiceInfo(
            uuid: KnownUUIDs.pulseOximeterService.uuidString,
            knownName: nil,
            characteristics: [char(KnownUUIDs.plxContinuousMeasurement.uuidString)]
        )]
    }

    private func batteryOnlyGATT() -> [ServiceInfo] {
        [ServiceInfo(
            uuid: KnownUUIDs.batteryService.uuidString,
            knownName: nil,
            characteristics: [char(KnownUUIDs.batteryLevel.uuidString)]
        )]
    }

    /// Drive discovery until `maxEvents` are collected or `deadline` elapses, then tear down.
    /// `probe` defaults true since these tests exercise the probing policy.
    @MainActor
    private func runDiscovery(
        _ fake: FakeProbe,
        probe: Bool = true,
        maxEvents: Int? = nil,
        deadline: Duration = .milliseconds(300)
    ) async -> [SupportedDevice] {
        let stream = discoverSupported(using: fake, probe: probe, probeTimeout: 0.1, scanWindow: 0.02)
        let consume = Task { @MainActor () -> [SupportedDevice] in
            var events: [SupportedDevice] = []
            for await dev in stream {
                events.append(dev)
                if let maxEvents, events.count >= maxEvents { break }
            }
            return events
        }
        let stopper = Task { @MainActor in
            try? await Task.sleep(for: deadline)
            consume.cancel()
        }
        let events = await consume.value
        stopper.cancel()
        return events
    }

    // MARK: Tests

    func testAdvertisedMatchYieldedWithoutProbing() async {
        let fake = FakeProbe(advertisements: [
            device(advertised: [KnownUUIDs.pulseOximeterService.uuidString], connectable: true),
        ])
        let events = await runDiscovery(fake, maxEvents: 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.confirmation, .advertised)
        XCTAssertEqual(events.first?.decoderName, "PLXSParser")
        XCTAssertTrue(fake.connectCalls.isEmpty, "an advertised match must not be probed")
    }

    func testConnectableUnknownProbedAndYielded() async {
        let dev = device(advertised: [], connectable: true)
        let fake = FakeProbe(advertisements: [dev], gattByID: [dev.id: plxsGATT()])
        let events = await runDiscovery(fake)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.confirmation, .probed)
        XCTAssertEqual(events.first?.decoderName, "PLXSParser")
        XCTAssertEqual(fake.connectCalls, [dev.id], "probed exactly once")
        XCTAssertGreaterThanOrEqual(fake.disconnectCalls, 1, "probe must disconnect afterwards")
    }

    func testAlreadyConnectedSupportedPeripheralSurfaced() async {
        // An already-connected device won't appear in a scan, but discovery surfaces it (with the
        // `.connected` confirmation and the right decoder) so it isn't "lost" — even in advertised-only
        // mode, and without probing.
        let dev = device(advertised: [KnownUUIDs.pulseOximeterService.uuidString], connectable: true)
        let fake = FakeProbe(advertisements: [], connected: [dev])
        let events = await runDiscovery(fake, probe: false)
        XCTAssertEqual(events.count, 1, "surfaced once, not repeatedly")
        XCTAssertEqual(events.first?.confirmation, .connected)
        XCTAssertEqual(events.first?.decoderName, "PLXSParser")
        XCTAssertTrue(fake.connectCalls.isEmpty, "an already-connected device is surfaced without probing")
    }

    func testProbesAtMostOnePerScanCycle() async {
        // Two connectable unknowns. One-per-cycle means a scan window precedes every probe, so the two
        // probes are never back-to-back; draining the whole queue in one cycle would emit adjacent
        // "connect" actions with no "scan" between them.
        let a = device(advertised: [], connectable: true)
        let b = device(advertised: [], connectable: true)
        let fake = FakeProbe(advertisements: [a, b], gattByID: [a.id: plxsGATT(), b.id: plxsGATT()])
        _ = await runDiscovery(fake, deadline: .milliseconds(300))
        XCTAssertEqual(fake.connectCalls.count, 2, "both probed exactly once")
        let backToBackProbes = zip(fake.actions, fake.actions.dropFirst())
            .contains { $0 == "connect" && $1 == "connect" }
        XCTAssertFalse(backToBackProbes, "probes must be separated by a scan window (one per cycle)")
    }

    func testProbeDisabledNeverConnects() async {
        // Default (advertised-only) mode: a connectable unknown whose GATT *would* match is never
        // probed — the engine must not connect to anything unless probing is explicitly enabled.
        let dev = device(advertised: [], connectable: true)
        let fake = FakeProbe(advertisements: [dev], gattByID: [dev.id: plxsGATT()])
        let events = await runDiscovery(fake, probe: false)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(fake.connectCalls.isEmpty, "advertised-only mode must never connect")
    }

    func testProbeDisabledStillYieldsAdvertised() async {
        // Advertised matches are surfaced in both modes.
        let dev = device(advertised: [KnownUUIDs.heartRateService.uuidString], connectable: true)
        let fake = FakeProbe(advertisements: [dev])
        let events = await runDiscovery(fake, probe: false, maxEvents: 1)
        XCTAssertEqual(events.first?.confirmation, .advertised)
        XCTAssertEqual(events.first?.decoderName, "HeartRateParser")
        XCTAssertTrue(fake.connectCalls.isEmpty)
    }

    func testNonConnectableUnknownSkipped() async {
        let dev = device(advertised: [], connectable: false)
        // Even though its (hypothetical) GATT would match, a non-connectable device is never probed.
        let fake = FakeProbe(advertisements: [dev], gattByID: [dev.id: plxsGATT()])
        let events = await runDiscovery(fake)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(fake.connectCalls.isEmpty)
    }

    func testProbedDeviceWithNoDecodableGATTNotYieldedButDisconnected() async {
        let dev = device(advertised: [], connectable: true)
        let fake = FakeProbe(advertisements: [dev], gattByID: [dev.id: batteryOnlyGATT()])
        let events = await runDiscovery(fake)
        XCTAssertTrue(events.isEmpty, "battery-only device is not decodable")
        XCTAssertEqual(fake.connectCalls, [dev.id], "probed once")
        XCTAssertGreaterThanOrEqual(fake.disconnectCalls, 1, "must disconnect even when nothing matched")
    }

    func testEachDeviceProbedAtMostOnce() async {
        // The fake re-advertises the same device on every scan window; the policy must probe it once.
        let dev = device(advertised: [], connectable: true)
        let fake = FakeProbe(advertisements: [dev], gattByID: [dev.id: plxsGATT()])
        let events = await runDiscovery(fake, deadline: .milliseconds(300))
        XCTAssertEqual(events.count, 1, "a confirmed device is yielded once, not every scan window")
        XCTAssertEqual(fake.connectCalls.count, 1, "probed at most once across many scan windows")
    }

    func testConnectFailureSkippedAndOthersStillProbed() async {
        let bad = device(advertised: [], connectable: true)
        let good = device(advertised: [], connectable: true)
        let fake = FakeProbe(
            advertisements: [bad, good],
            gattByID: [good.id: plxsGATT()],
            connectFailIDs: [bad.id]
        )
        let events = await runDiscovery(fake)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.peripheral.id, good.id)
        XCTAssertTrue(fake.connectCalls.contains(bad.id), "the unreachable device was attempted")
        XCTAssertTrue(fake.connectCalls.contains(good.id), "and the next candidate still got probed")
    }
}
