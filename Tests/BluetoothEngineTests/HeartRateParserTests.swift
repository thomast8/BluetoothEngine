import XCTest
@testable import BluetoothEngine

/// Frames are real captures from a Whoop 5.0 in "Broadcast Heart Rate" mode (plus a few synthesized
/// edge cases the band didn't happen to emit). RR-interval ticks are 1/1024 s; expected milliseconds
/// are `ticks / 1024 * 1000`, asserted with a small accuracy to absorb the float conversion.
final class HeartRateParserTests: XCTestCase {
    private let parser = HeartRateParser()

    private func parse(_ bytes: [UInt8]) -> VitalsMeasurement? {
        parser.parse(characteristic: KnownUUIDs.heartRateMeasurement, value: Data(bytes))
    }

    func testEightBitHeartRateNoRR() {
        // flags=0x00 | HR=64 (0x40) — captured.
        let frame = Data([0x00, 0x40])
        let m = parser.parse(characteristic: KnownUUIDs.heartRateMeasurement, value: frame)
        XCTAssertEqual(m?.pulseRate, 64)
        XCTAssertNil(m?.spo2, "Heart Rate Service carries no SpO2")
        XCTAssertNil(m?.rrIntervalsMillis)
        XCTAssertEqual(m?.contactDetected, true)
        XCTAssertEqual(m?.quality, .good)
        XCTAssertEqual(m?.raw, frame)
    }

    func testSingleRRInterval() {
        // flags=0x10 (RR present) | HR=64 | RR=0x0381 (897 ticks → 875.98 ms) — captured.
        let m = parse([0x10, 0x40, 0x81, 0x03])
        XCTAssertEqual(m?.pulseRate, 64)
        XCTAssertEqual(m?.rrIntervalsMillis?.count, 1)
        XCTAssertEqual(m?.rrIntervalsMillis?.first ?? 0, 875.98, accuracy: 0.5)
    }

    func testMultipleRRIntervals() {
        // flags=0x10 | HR=62 | RR×3 = 0x03C9,0x036E,0x03CF (969,878,975 ticks) — captured.
        let m = parse([0x10, 0x3E, 0xC9, 0x03, 0x6E, 0x03, 0xCF, 0x03])
        XCTAssertEqual(m?.pulseRate, 62)
        let rr = m?.rrIntervalsMillis
        XCTAssertEqual(rr?.count, 3)
        XCTAssertEqual(rr?[0] ?? 0, 946.29, accuracy: 0.5)
        XCTAssertEqual(rr?[1] ?? 0, 857.42, accuracy: 0.5)
        XCTAssertEqual(rr?[2] ?? 0, 952.15, accuracy: 0.5)
    }

    func testEnergyExpendedOffsetSkippedBeforeRR() {
        // flags=0x18 (energy expended + RR present) | HR=72 | Energy=500 (0xF4,0x01 LE) | RR=0x0381.
        // If the energy-expended skip is dropped, the RR read starts on the energy bytes and yields
        // ~488 ms instead of 876 ms — a plausible-but-wrong value that no other test would catch.
        let m = parse([0x18, 0x48, 0xF4, 0x01, 0x81, 0x03])
        XCTAssertEqual(m?.pulseRate, 72)
        XCTAssertEqual(m?.rrIntervalsMillis?.count, 1)
        XCTAssertEqual(m?.rrIntervalsMillis?.first ?? 0, 875.98, accuracy: 0.5)
    }

    func testEnergyExpendedOnlyNoRR() {
        // flags=0x08 (energy expended present, RR absent) | HR=72 | Energy=500 LE.
        let m = parse([0x08, 0x48, 0xF4, 0x01])
        XCTAssertEqual(m?.pulseRate, 72)
        XCTAssertNil(m?.rrIntervalsMillis)
    }

    func testRRFlagSetButNoIntervalBytes() {
        // flags=0x10 claims RR present but only the HR byte follows — report nil, not an empty array.
        let m = parse([0x10, 0x48])
        XCTAssertEqual(m?.pulseRate, 72)
        XCTAssertNil(m?.rrIntervalsMillis)
    }

    func testSixteenBitHeartRate() {
        // flags=0x01 (16-bit HR) | HR=0x0048=72 (LE).
        let m = parse([0x01, 0x48, 0x00])
        XCTAssertEqual(m?.pulseRate, 72)
    }

    func testSixteenBitFlagButTruncatedReturnsNil() {
        // flags claims a 16-bit HR but only one HR byte follows — structurally invalid.
        XCTAssertNil(parse([0x01, 0x40]))
    }

    func testContactSupportedAndDetected() {
        // flags=0x06: Sensor Contact Supported (bit2) + Status detected (bit1).
        let m = parse([0x06, 0x40])
        XCTAssertEqual(m?.pulseRate, 64)
        XCTAssertEqual(m?.contactDetected, true)
        XCTAssertEqual(m?.quality, .good)
    }

    func testContactSupportedNotDetected() {
        // flags=0x04: Supported but not detected — band off the wrist despite a stale HR byte.
        let m = parse([0x04, 0x40])
        XCTAssertEqual(m?.pulseRate, 64)
        XCTAssertEqual(m?.contactDetected, false)
        XCTAssertEqual(m?.quality, .noContact)
    }

    func testZeroHeartRateIsNoReading() {
        // HR=0 is non-physiological; contact unsupported → searching.
        let m = parse([0x00, 0x00])
        XCTAssertNil(m?.pulseRate)
        XCTAssertEqual(m?.contactDetected, false)
        XCTAssertEqual(m?.quality, .searching)
    }

    func testTooShortReturnsNil() {
        XCTAssertNil(parse([0x00]))
        XCTAssertNil(parser.parse(characteristic: KnownUUIDs.heartRateMeasurement, value: Data()))
    }

    func testWrongCharacteristicReturnsNil() {
        XCTAssertNil(parser.parse(characteristic: KnownUUIDs.batteryLevel, value: Data([0x00, 0x40])))
    }

    func testInterpretContactDirectly() {
        XCTAssertEqual(HeartRateParser.interpretContact(flags: 0x06, hasPulse: true).0, true)
        XCTAssertEqual(HeartRateParser.interpretContact(flags: 0x04, hasPulse: true).1, .noContact)
        let unsupportedWithPulse = HeartRateParser.interpretContact(flags: 0x00, hasPulse: true)
        XCTAssertEqual(unsupportedWithPulse.0, true)
        XCTAssertEqual(unsupportedWithPulse.1, .good)
        XCTAssertEqual(HeartRateParser.interpretContact(flags: 0x00, hasPulse: false).1, .searching)
    }
}
