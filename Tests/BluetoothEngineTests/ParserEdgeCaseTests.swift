import XCTest
@testable import BluetoothEngine

/// Edge cases the review flagged: SFLOAT special-value gating + exponent coverage, the PLXS optional-
/// field offset arithmetic (so a regression in the field-skipping math can't silently misread status),
/// spot-check zero handling, and the pure helpers.
final class ParserEdgeCaseTests: XCTestCase {
    private let parser = PLXSParser()

    private func frame(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    // MARK: SFLOAT

    func testPositiveExponent() {
        // exponent +1 (nibble 0x1), mantissa 5 → 50.0
        XCTAssertEqual(SFLOAT.decode(0x1005), 50.0)
    }

    func testReservedAndInfinityReturnNil() {
        XCTAssertNil(SFLOAT.decode(0x0801)) // reserved
        XCTAssertNil(SFLOAT.decode(0x07FE)) // +Inf
        XCTAssertNil(SFLOAT.decode(0x0802)) // -Inf
    }

    func testSentinelMantissaWithNonzeroExponentIsOrdinaryNumber() {
        // 0xF7FF: exponent -1, mantissa 2047 → 204.7 — must NOT be treated as the NaN sentinel.
        XCTAssertEqual(try XCTUnwrap(SFLOAT.decode(0xF7FF)), 204.7, accuracy: 1e-9)
    }

    // MARK: PLXS offset arithmetic

    func testContinuousOffsetWithFastAndMeasurementStatusFlags() {
        // flags=0x0D (Fast 0x01 + MeasurementStatus 0x04 + DeviceStatus 0x08). The device-status field
        // therefore sits at offset 5 + 4 (fast) + 2 (meas status) = 11. Put bit 11 (sensor unconnected)
        // there and confirm the parser reads status from the shifted offset (→ finger out).
        let f = frame("0D 62 00 3C 00 FF FF FF FF 00 00 00 08 00")
        let m = parser.parse(characteristic: KnownUUIDs.plxContinuousMeasurement, value: f)
        XCTAssertEqual(m?.fingerDetected, false)
        XCTAssertEqual(m?.quality, .noFinger)
        XCTAssertNil(m?.spo2)
    }

    func testContinuousStatusFlagSetButFrameTooShortFallsBackToSFLOAT() {
        // flags claims device-status present, but the frame is exactly the 5 mandatory bytes.
        let f = frame("08 62 00 3C 00")
        let m = parser.parse(characteristic: KnownUUIDs.plxContinuousMeasurement, value: f)
        XCTAssertEqual(m?.spo2, 98)
        XCTAssertEqual(m?.fingerDetected, true)
        XCTAssertEqual(m?.quality, .good)
    }

    // MARK: spot-check zero suppression

    func testSpotCheckZeroYieldsNoFinger() {
        let f = frame("00 00 00 00 00")
        let m = parser.parse(characteristic: KnownUUIDs.plxSpotCheckMeasurement, value: f)
        XCTAssertNil(m?.spo2)
        XCTAssertEqual(m?.fingerDetected, false)
        XCTAssertEqual(m?.quality, .searching)
    }

    // MARK: pure helpers

    func testNoReadingToNilSuppressesZeroAndNegative() {
        XCTAssertNil(PLXSParser.noReadingToNil(0))
        XCTAssertNil(PLXSParser.noReadingToNil(-1))
        XCTAssertEqual(PLXSParser.noReadingToNil(98), 98)
    }

    func testInterpretDeviceStatusPoorSignal() {
        let (finger, quality) = PLXSParser.interpretDeviceStatus(1 << 4, spo2: 98)
        XCTAssertTrue(finger)
        XCTAssertEqual(quality, .lowPerfusion)
    }

    func testInterpretDeviceStatusLowPerfusionWithoutReading() {
        let (finger, quality) = PLXSParser.interpretDeviceStatus(1 << 5, spo2: nil)
        XCTAssertFalse(finger)
        XCTAssertEqual(quality, .lowPerfusion)
    }
}
