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
        [PLXSParser()]
    }

    /// GATT service UUIDs the engine can decode. Pass to `BLECentral.scan(filterServices:)` to have
    /// CoreBluetooth surface only compatible peripherals (the OS filters on advertised services).
    public static var serviceUUIDs: [CBUUID] {
        parsers.map(\.serviceUUID)
    }

    /// Whether a discovered peripheral advertises a service this engine supports.
    public static func supports(_ peripheral: DiscoveredPeripheral) -> Bool {
        let supported = Set(serviceUUIDs.map { $0.uuidString.uppercased() })
        return peripheral.advertisedServices.contains { supported.contains($0.uppercased()) }
    }

    /// The parser to use for a peripheral given its discovered/advertised service UUIDs, or nil if
    /// none match.
    public static func parser(forServiceUUIDs uuids: [String]) -> MeasurementParser? {
        let wanted = Set(uuids.map { $0.uppercased() })
        return parsers.first { wanted.contains($0.serviceUUID.uuidString.uppercased()) }
    }
}
