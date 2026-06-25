import CoreBluetooth
import XCTest
@testable import BluetoothEngine

final class SupportedDevicesTests: XCTestCase {
    private func peripheral(services: [String]) -> DiscoveredPeripheral {
        DiscoveredPeripheral(id: UUID(), name: "x", rssi: -50, advertisedServices: services, isConnectable: true)
    }

    func testSupportsMatchesPulseOximeterService() {
        // Round-trips KnownUUIDs.pulseOximeterService through CBUUID.uuidString exactly as discovery
        // does, so this proves the match works regardless of short-vs-128-bit string representation.
        let plxs = KnownUUIDs.pulseOximeterService.uuidString
        XCTAssertTrue(SupportedDevices.supports(peripheral(services: [plxs])))
    }

    func testSupportsIsCaseInsensitive() {
        let plxs = KnownUUIDs.pulseOximeterService.uuidString
        XCTAssertTrue(SupportedDevices.supports(peripheral(services: [plxs.lowercased()])))
        XCTAssertTrue(SupportedDevices.supports(peripheral(services: [plxs.uppercased()])))
    }

    func testDoesNotSupportUnrelatedService() {
        XCTAssertFalse(SupportedDevices.supports(peripheral(services: [KnownUUIDs.batteryService.uuidString])))
    }

    func testEmptyAdvertisedServicesNotSupported() {
        XCTAssertFalse(SupportedDevices.supports(peripheral(services: [])))
    }

    func testSupportsMatchesHeartRateService() {
        // A Whoop in Broadcast Heart Rate mode advertises 0x180D.
        let hrs = KnownUUIDs.heartRateService.uuidString
        XCTAssertTrue(SupportedDevices.supports(peripheral(services: [hrs])))
    }

    func testParserForServiceUUIDsReturnsPLXS() {
        let parser = SupportedDevices.parser(forServiceUUIDs: [KnownUUIDs.pulseOximeterService.uuidString])
        XCTAssertEqual(parser?.serviceUUID, KnownUUIDs.pulseOximeterService)
    }

    func testParserForServiceUUIDsReturnsHeartRate() {
        let parser = SupportedDevices.parser(forServiceUUIDs: [KnownUUIDs.heartRateService.uuidString])
        XCTAssertTrue(parser is HeartRateParser)
        XCTAssertEqual(parser?.serviceUUID, KnownUUIDs.heartRateService)
    }

    func testParserForUnsupportedServiceReturnsNil() {
        XCTAssertNil(SupportedDevices.parser(forServiceUUIDs: [KnownUUIDs.batteryService.uuidString]))
    }

    func testServiceUUIDsIncludesPulseOximeterAndHeartRate() {
        XCTAssertTrue(SupportedDevices.serviceUUIDs.contains(KnownUUIDs.pulseOximeterService))
        XCTAssertTrue(SupportedDevices.serviceUUIDs.contains(KnownUUIDs.heartRateService))
    }
}

final class KnownUUIDsTests: XCTestCase {
    func testNameForKnownUUIDs() {
        XCTAssertEqual(KnownUUIDs.name(for: KnownUUIDs.pulseOximeterService), "Pulse Oximeter Service")
        XCTAssertEqual(KnownUUIDs.name(for: KnownUUIDs.plxContinuousMeasurement), "PLX Continuous Measurement")
        XCTAssertEqual(KnownUUIDs.name(for: KnownUUIDs.heartRateService), "Heart Rate Service")
        XCTAssertEqual(KnownUUIDs.name(for: KnownUUIDs.heartRateMeasurement), "Heart Rate Measurement")
        XCTAssertEqual(KnownUUIDs.name(for: KnownUUIDs.bodySensorLocation), "Body Sensor Location")
        XCTAssertEqual(KnownUUIDs.name(for: KnownUUIDs.batteryLevel), "Battery Level")
    }

    func testNameForUnknownReturnsNil() {
        XCTAssertNil(KnownUUIDs.name(for: CBUUID(string: "FFF0")))
    }
}
