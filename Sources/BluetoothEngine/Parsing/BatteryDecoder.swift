import CoreBluetooth
import Foundation

/// Decoder for the standard Battery Level characteristic (`0x2A19`): a single `UInt8` percentage.
public enum BatteryDecoder {
    /// Decode a Battery Level payload to a `0...100` percentage, or nil if empty / out of range.
    public static func level(from data: Data) -> Int? {
        guard let byte = data.first else { return nil }
        let value = Int(byte)
        return (0...100).contains(value) ? value : nil
    }
}

/// Transforms a raw-notification stream into battery-level percentages.
///
/// The sibling of `vitalsMeasurements(from:parser:)`: same transport seam, different domain. Keeps
/// battery off `VitalsMeasurement` (different characteristic, different cadence) so the decode layer
/// stays stateless. Frames on any characteristic other than Battery Level (`0x2A19`) are dropped.
/// Battery is read once on connect via `BLECentral.readBatteryLevel()`; this stream surfaces the
/// subsequent change notifications, for devices that notify on `0x2A19`.
public func batteryLevels(
    from notifications: AsyncStream<RawNotification>
) -> AsyncStream<Int> {
    AsyncStream(bufferingPolicy: .bufferingNewest(BLEStreamLimits.batteryLevels)) { continuation in
        let task = Task {
            for await note in notifications {
                guard CBUUID(string: note.characteristicUUID) == KnownUUIDs.batteryLevel else { continue }
                if let level = BatteryDecoder.level(from: note.data) {
                    continuation.yield(level)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
