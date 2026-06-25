import CoreBluetooth

/// The engine's declaration of *what it can talk to*. This is the capability the stack owns; the app
/// owns the policy of what to do with it (show only supported devices, auto-connect the nearest one,
/// badge supported vs. ignore the rest). Keeping this here is what lets an app avoid the "list every
/// AirPod and beacon in the room" smell — it can scan filtered to `serviceUUIDs` or post-filter
/// discoveries with `supports(_:)`, instead of guessing.
public enum SupportedDevices {
    /// Parsers the engine ships with. The proprietary stub is intentionally excluded — it isn't a
    /// real capability until its protocol is implemented.
    public static var parsers: [MeasurementParser] {
        [PLXSParser(), HeartRateParser()]
    }

    /// GATT service UUIDs the engine can decode. Pass to `BLECentral.scan(filterServices:)` to have
    /// CoreBluetooth surface only compatible peripherals (the OS filters on advertised services).
    public static var serviceUUIDs: [CBUUID] {
        parsers.map(\.serviceUUID)
    }

    /// Whether a discovered peripheral *advertises* a service this engine supports. This is a
    /// best-effort **hint** only: a BLE advertisement carries service UUIDs (never characteristics),
    /// and many devices (e.g. cheap oximeters) don't advertise their primary service at all — so a
    /// `false` here does **not** mean unsupported. The authoritative check is `supports(_ services:)`
    /// /`parser(for:)` against the GATT read after connecting.
    public static func supports(_ peripheral: DiscoveredPeripheral) -> Bool {
        let supported = Set(serviceUUIDs.map { $0.uuidString.uppercased() })
        return peripheral.advertisedServices.contains { supported.contains($0.uppercased()) }
    }

    /// The parser for a peripheral given a list of *service* UUID strings (advertised or discovered),
    /// or nil if none match. Service-only — for the authoritative post-connection check that also
    /// considers characteristics, use `parser(for: [ServiceInfo])`. When more than one parser matches,
    /// the first in `parsers` wins.
    public static func parser(forServiceUUIDs uuids: [String]) -> MeasurementParser? {
        let wanted = Set(uuids.map { $0.uppercased() })
        return parsers.first { wanted.contains($0.serviceUUID.uuidString.uppercased()) }
    }

    /// The decoder for a *connected* peripheral, chosen from its discovered GATT, or nil if nothing
    /// matches. A parser matches when the inventory exposes EITHER its `serviceUUID` among the services
    /// OR any of its `characteristicUUIDs` among the discovered characteristics (flattened across
    /// services). The characteristic path is what lets a device that carries a standard characteristic
    /// (e.g. PLX Continuous Measurement, `0x2A5F`) under a *non-standard* vendor service still be
    /// recognised — it "conforms to something we already decode", judged by structure, not by name.
    ///
    /// This is the authoritative, post-connection counterpart to the advertised-only `supports(_:)`
    /// hint. Comparison is uppercased-set membership of `CBUUID.uuidString`, so it is case-insensitive
    /// and matches how CoreBluetooth renders SIG-assigned UUIDs in the short form the parsers declare
    /// (mirrors `parser(forServiceUUIDs:)`). When more than one parser matches, the first in `parsers`
    /// wins.
    public static func parser(for services: [ServiceInfo]) -> MeasurementParser? {
        let serviceSet = Set(services.map { $0.uuid.uppercased() })
        let charSet = Set(services.flatMap(\.characteristics).map { $0.uuid.uppercased() })
        return parsers.first { parser in
            if serviceSet.contains(parser.serviceUUID.uuidString.uppercased()) { return true }
            return parser.characteristicUUIDs.contains { charSet.contains($0.uuidString.uppercased()) }
        }
    }

    /// Whether the engine can decode this *connected* peripheral, judged from its discovered GATT
    /// (services AND characteristics). Authoritative counterpart to the advertised `supports(_:)` hint.
    public static func supports(_ services: [ServiceInfo]) -> Bool {
        parser(for: services) != nil
    }
}
