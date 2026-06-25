import XCTest
@testable import BluetoothEngine

final class PLXFeaturesTests: XCTestCase {
    func testDecodesBitfield() throws {
        // bits 0,1,3 set → 0x000B (measStatus, devStatus, timestamp), little-endian [0x0B, 0x00].
        let features = try XCTUnwrap(PLXFeatures.decode(Data([0x0B, 0x00])))
        XCTAssertTrue(features.measurementStatusSupported)
        XCTAssertTrue(features.deviceSensorStatusSupported)
        XCTAssertFalse(features.spotCheckStorageSupported)
        XCTAssertTrue(features.timestampSupported)
        XCTAssertFalse(features.fastMetricSupported)
        XCTAssertEqual(features.raw, 0x000B)
    }

    func testAllLowByteBitsSet() throws {
        let features = try XCTUnwrap(PLXFeatures.decode(Data([0xFF, 0x00])))
        XCTAssertTrue(features.measurementStatusSupported)
        XCTAssertTrue(features.fastMetricSupported)
        XCTAssertTrue(features.slowMetricSupported)
        XCTAssertTrue(features.pulseAmplitudeIndexSupported)
        XCTAssertTrue(features.multipleBondsSupported)
    }

    func testReadsLittleEndianAndIgnoresTrailingBytes() throws {
        // Supported Features = 0x0001 in the first two bytes; any following optional fields ignored.
        let features = try XCTUnwrap(PLXFeatures.decode(Data([0x01, 0x00, 0xAB, 0xCD])))
        XCTAssertTrue(features.measurementStatusSupported)
        XCTAssertFalse(features.deviceSensorStatusSupported)
        XCTAssertEqual(features.raw, 0x0001)
    }

    func testRejectsShortPayload() {
        XCTAssertNil(PLXFeatures.decode(Data([0x0B])))
        XCTAssertNil(PLXFeatures.decode(Data()))
    }
}
