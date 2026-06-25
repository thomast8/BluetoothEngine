import CoreBluetooth
import XCTest
@testable import BluetoothEngine

final class DeviceInfoDecoderTests: XCTestCase {
    func testDecodesUTF8Fields() {
        let values: [CBUUID: Data] = [
            KnownUUIDs.manufacturerName: Data("ChoiceMMed".utf8),
            KnownUUIDs.modelNumber: Data("MD300C208S".utf8),
            KnownUUIDs.firmwareRevision: Data("1.0.0".utf8),
        ]
        let info = DeviceInfoDecoder.decode(values)
        XCTAssertEqual(info.manufacturerName, "ChoiceMMed")
        XCTAssertEqual(info.modelNumber, "MD300C208S")
        XCTAssertEqual(info.firmwareRevision, "1.0.0")
        XCTAssertNil(info.serialNumber)
        XCTAssertFalse(info.isEmpty)
    }

    func testTrimsNulPaddingAndTreatsBlankAsNil() {
        let values: [CBUUID: Data] = [
            KnownUUIDs.serialNumber: Data("SN123\0\0".utf8), // NUL-padded by firmware
            KnownUUIDs.hardwareRevision: Data(),             // empty → nil
            KnownUUIDs.softwareRevision: Data("   ".utf8),   // whitespace-only → nil
        ]
        let info = DeviceInfoDecoder.decode(values)
        XCTAssertEqual(info.serialNumber, "SN123")
        XCTAssertNil(info.hardwareRevision)
        XCTAssertNil(info.softwareRevision)
    }

    func testEmptyMapIsEmptyDeviceInfo() {
        XCTAssertTrue(DeviceInfoDecoder.decode([:]).isEmpty)
    }
}
