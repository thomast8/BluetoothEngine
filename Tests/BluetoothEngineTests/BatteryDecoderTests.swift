import XCTest
@testable import BluetoothEngine

final class BatteryDecoderTests: XCTestCase {
    func testLevelDecodesValidPercentages() {
        XCTAssertEqual(BatteryDecoder.level(from: Data([0x32])), 50)
        XCTAssertEqual(BatteryDecoder.level(from: Data([0x00])), 0)
        XCTAssertEqual(BatteryDecoder.level(from: Data([0x64])), 100)
    }

    func testLevelRejectsEmptyAndOutOfRange() {
        XCTAssertNil(BatteryDecoder.level(from: Data()))
        XCTAssertNil(BatteryDecoder.level(from: Data([0x65])), "101% is out of range")
        XCTAssertNil(BatteryDecoder.level(from: Data([0xFF])), "255 (0xFF sentinel) is out of range")
    }

    func testBatteryLevelsStreamFiltersAndDecodes() async {
        let (raw, continuation) = AsyncStream<RawNotification>.makeStream()
        // A battery-level notification → yields 75.
        continuation.yield(RawNotification(
            characteristicUUID: KnownUUIDs.batteryLevel.uuidString,
            data: Data([0x4B]), monotonicSeconds: 0, wallClock: Date()
        ))
        // A pulse-ox measurement notification → dropped by the battery stream.
        continuation.yield(RawNotification(
            characteristicUUID: KnownUUIDs.plxContinuousMeasurement.uuidString,
            data: Data([0x00, 0x62, 0x00, 0x3C, 0x00]), monotonicSeconds: 0, wallClock: Date()
        ))
        continuation.finish()

        var levels: [Int] = []
        for await level in batteryLevels(from: raw) { levels.append(level) }

        XCTAssertEqual(levels, [75], "only the 0x2A19 frame should decode; the measurement frame is dropped")
    }
}
