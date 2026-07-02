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

    // MARK: GATT-based (post-connection) matcher — parser(for:) / supports(_ services:)

    private func char(_ uuid: String) -> CharacteristicInfo {
        CharacteristicInfo(uuid: uuid, knownName: nil, propertiesRaw: 0x10, value: nil, descriptors: [])
    }

    private func service(_ uuid: String, _ chars: [CharacteristicInfo] = []) -> ServiceInfo {
        ServiceInfo(uuid: uuid, knownName: nil, characteristics: chars)
    }

    func testParserForServicesMatchesStandardPLXSTree() {
        // A standard pulse-ox GATT — PLXS (0x1822) with continuous + spot-check, alongside the usual
        // device-info and battery services. Recognised by structure (service match), no name involved.
        let services = [
            service(KnownUUIDs.pulseOximeterService.uuidString, [
                char(KnownUUIDs.plxContinuousMeasurement.uuidString),
                char(KnownUUIDs.plxSpotCheckMeasurement.uuidString),
            ]),
            service(KnownUUIDs.deviceInformation.uuidString),
            service(KnownUUIDs.batteryService.uuidString, [char(KnownUUIDs.batteryLevel.uuidString)]),
        ]
        XCTAssertTrue(SupportedDevices.parser(for: services) is PLXSParser)
        XCTAssertTrue(SupportedDevices.supports(services))
    }

    func testParserForServicesMatchesStandardCharacteristicUnderVendorService() {
        // The crux: a non-standard 128-bit vendor service that nonetheless exposes the standard PLX
        // Continuous Measurement characteristic (0x2A5F). No 0x1822 anywhere — matched by characteristic,
        // proving "conforms to something we already decode" independent of the service wrapper.
        let vendorService = "0000FE00-1234-5678-9ABC-DEF012345678"
        let services = [service(vendorService, [char(KnownUUIDs.plxContinuousMeasurement.uuidString)])]
        XCTAssertTrue(SupportedDevices.parser(for: services) is PLXSParser)
        XCTAssertTrue(SupportedDevices.supports(services))
    }

    func testParserForServicesMatchesHeartRateByCharacteristic() {
        // Heart Rate Measurement (0x2A37) under a vendor service still resolves to the HR parser.
        let vendorService = "0000ABCD-1234-5678-9ABC-DEF012345678"
        let services = [service(vendorService, [char(KnownUUIDs.heartRateMeasurement.uuidString)])]
        XCTAssertTrue(SupportedDevices.parser(for: services) is HeartRateParser)
    }

    func testParserForServicesIsCaseInsensitive() {
        // CoreBluetooth renders SIG UUIDs in short form; matching is case-insensitive over that form.
        let services = [service(KnownUUIDs.pulseOximeterService.uuidString.lowercased(), [
            char(KnownUUIDs.plxContinuousMeasurement.uuidString.lowercased()),
        ])]
        XCTAssertTrue(SupportedDevices.parser(for: services) is PLXSParser)
    }

    func testParserForInformationalOnlyServicesReturnsNil() {
        // Device-info + battery only — nothing we decode. Must not be marked supported.
        let services = [
            service(KnownUUIDs.deviceInformation.uuidString),
            service(KnownUUIDs.batteryService.uuidString, [char(KnownUUIDs.batteryLevel.uuidString)]),
        ]
        XCTAssertNil(SupportedDevices.parser(for: services))
        XCTAssertFalse(SupportedDevices.supports(services))
    }

    func testParserForEmptyServicesReturnsNil() {
        XCTAssertNil(SupportedDevices.parser(for: []))
        XCTAssertFalse(SupportedDevices.supports([]))
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
