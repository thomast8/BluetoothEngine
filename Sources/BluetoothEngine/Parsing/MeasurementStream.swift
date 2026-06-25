import CoreBluetooth
import Foundation

/// Transforms a raw-notification stream into decoded measurements using a `MeasurementParser`.
///
/// This is the seam between transport and domain: `BLECentral` produces `RawNotification`s and knows
/// nothing about any sensor profile; this free function applies a parser and yields `VitalsMeasurement`s.
/// Frames the parser can't decode (wrong characteristic, pleth-only, etc.) are dropped. The work runs
/// in a child task that is cancelled when the returned stream is dropped, and finishes when the source
/// stream finishes.
public func vitalsMeasurements(
    from notifications: AsyncStream<RawNotification>,
    parser: MeasurementParser
) -> AsyncStream<VitalsMeasurement> {
    AsyncStream(bufferingPolicy: .bufferingNewest(BLEStreamLimits.decodedMeasurements)) { continuation in
        let task = Task {
            for await note in notifications {
                let characteristic = CBUUID(string: note.characteristicUUID)
                if let measurement = parser.parse(characteristic: characteristic, value: note.data) {
                    continuation.yield(measurement)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
