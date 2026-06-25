import CoreBluetooth
import Foundation

/// Decoder for the standard Bluetooth SIG Heart Rate Service (0x180D): Heart Rate Measurement
/// (0x2A37). A Whoop band in "Broadcast Heart Rate" mode implements exactly this profile — live
/// heart rate plus, on some frames, beat-to-beat RR-intervals (the raw signal for HRV).
///
/// Frame layout (per spec): `flags(1) | HR (uint8 or uint16 LE) | [Energy Expended uint16 LE] |
/// [RR-intervals: uint16 LE each, units 1/1024 s]`. SpO2 is not part of this profile, so it is left
/// nil; the heart rate maps onto `pulseRate` and RR-intervals onto `rrIntervalsMillis`.
public struct HeartRateParser: MeasurementParser {
    public init() {}

    public var serviceUUID: CBUUID { KnownUUIDs.heartRateService }
    public var characteristicUUIDs: [CBUUID] { [KnownUUIDs.heartRateMeasurement] }

    public func parse(characteristic: CBUUID, value data: Data) -> VitalsMeasurement? {
        guard characteristic == KnownUUIDs.heartRateMeasurement else { return nil }
        // flags(1) + at least one HR byte.
        guard data.count >= 2 else { return nil }

        // Copy to a 0-based buffer so offset arithmetic is independent of any Data slice startIndex.
        let bytes = [UInt8](data)
        let flags = bytes[0]
        let hr16 = flags & 0x01 != 0 // bit0: HR value format (0 = uint8, 1 = uint16)
        let energyPresent = flags & 0x08 != 0 // bit3: Energy Expended present
        let rrPresent = flags & 0x10 != 0 // bit4: one or more RR-intervals present

        var offset = 1
        let hrRaw: Int
        if hr16 {
            guard offset + 1 < bytes.count else { return nil }
            hrRaw = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2
        } else {
            hrRaw = Int(bytes[offset])
            offset += 1
        }
        // A heart rate of 0 is non-physiological — treat as "no reading" (band off-wrist / warming up).
        let pulse: Double? = hrRaw > 0 ? Double(hrRaw) : nil

        if energyPresent { offset += 2 } // Energy Expended (uint16) — present on some devices, not surfaced.

        var rr: [Double]?
        if rrPresent {
            var intervals: [Double] = []
            while offset + 1 < bytes.count {
                let ticks = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                offset += 2
                // RR-intervals are in units of 1/1024 second; convert to milliseconds.
                intervals.append(Double(ticks) / 1024.0 * 1000.0)
            }
            rr = intervals.isEmpty ? nil : intervals
        }

        let (contact, quality) = Self.interpretContact(flags: flags, hasPulse: pulse != nil)

        return VitalsMeasurement(
            pulseRate: pulse,
            rrIntervalsMillis: rr,
            contactDetected: contact,
            quality: quality,
            raw: data
        )
    }

    /// Map the Heart Rate Measurement sensor-contact flag bits to (contactDetected, quality).
    /// bit2 = Sensor Contact Supported, bit1 = Sensor Contact Status. When the device doesn't support
    /// the feature (a Whoop sends `00`), fall back to "a plausible pulse means the band is worn".
    static func interpretContact(flags: UInt8, hasPulse: Bool) -> (Bool, SignalQuality) {
        let supported = flags & 0x04 != 0
        let detected = flags & 0x02 != 0
        if supported {
            return detected ? (true, .good) : (false, .noContact)
        }
        return hasPulse ? (true, .good) : (false, .searching)
    }
}
