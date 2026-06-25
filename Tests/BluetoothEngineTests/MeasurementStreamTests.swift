import XCTest
@testable import BluetoothEngine

final class MeasurementStreamTests: XCTestCase {
    func testDecodesMeasurementsAndDropsUndecodableFrames() async {
        let (raw, continuation) = AsyncStream<RawNotification>.makeStream()
        // A valid PLX Continuous frame (SpO2 98, PR 60)...
        continuation.yield(RawNotification(
            characteristicUUID: KnownUUIDs.plxContinuousMeasurement.uuidString,
            data: Data([0x00, 0x62, 0x00, 0x3C, 0x00]),
            monotonicSeconds: 0, wallClock: Date()
        ))
        // ...and a battery-level notification, which the parser can't decode → must be dropped.
        continuation.yield(RawNotification(
            characteristicUUID: KnownUUIDs.batteryLevel.uuidString,
            data: Data([0x32]),
            monotonicSeconds: 0, wallClock: Date()
        ))
        continuation.finish()

        var results: [VitalsMeasurement] = []
        for await measurement in vitalsMeasurements(from: raw, parser: PLXSParser()) {
            results.append(measurement)
        }

        XCTAssertEqual(results.count, 1, "only the PLX frame should decode; the battery frame is dropped")
        XCTAssertEqual(results.first?.spo2, 98)
        XCTAssertEqual(results.first?.pulseRate, 60)
    }
}
