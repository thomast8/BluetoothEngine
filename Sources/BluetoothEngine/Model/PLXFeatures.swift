import Foundation

/// Decoded "Supported Features" field of PLX Features (`0x2A60`).
///
/// Read once on connect: it advertises which optional measurement fields and status reports the
/// oximeter implements, so an app (or a future smarter parser) can know a device's capabilities
/// instead of inferring them frame-by-frame. We decode the mandatory 16-bit Supported Features
/// bitfield; the optional Measurement-Status-Support / Device-and-Sensor-Status-Support fields that
/// may follow are not needed for capability reporting.
public struct PLXFeatures: Sendable, Equatable {
    public var measurementStatusSupported: Bool
    public var deviceSensorStatusSupported: Bool
    public var spotCheckStorageSupported: Bool
    public var timestampSupported: Bool
    public var fastMetricSupported: Bool
    public var slowMetricSupported: Bool
    public var pulseAmplitudeIndexSupported: Bool
    public var multipleBondsSupported: Bool
    public var raw: UInt16

    public init(
        measurementStatusSupported: Bool = false,
        deviceSensorStatusSupported: Bool = false,
        spotCheckStorageSupported: Bool = false,
        timestampSupported: Bool = false,
        fastMetricSupported: Bool = false,
        slowMetricSupported: Bool = false,
        pulseAmplitudeIndexSupported: Bool = false,
        multipleBondsSupported: Bool = false,
        raw: UInt16 = 0
    ) {
        self.measurementStatusSupported = measurementStatusSupported
        self.deviceSensorStatusSupported = deviceSensorStatusSupported
        self.spotCheckStorageSupported = spotCheckStorageSupported
        self.timestampSupported = timestampSupported
        self.fastMetricSupported = fastMetricSupported
        self.slowMetricSupported = slowMetricSupported
        self.pulseAmplitudeIndexSupported = pulseAmplitudeIndexSupported
        self.multipleBondsSupported = multipleBondsSupported
        self.raw = raw
    }

    /// Decode the leading little-endian `UInt16` Supported Features bitfield. Returns nil for a
    /// payload too short to contain it.
    public static func decode(_ data: Data) -> PLXFeatures? {
        guard data.count >= 2 else { return nil }
        let lo = UInt16(data[data.startIndex])
        let hi = UInt16(data[data.startIndex + 1])
        let bits = lo | (hi << 8)
        return PLXFeatures(
            measurementStatusSupported: bits & (1 << 0) != 0,
            deviceSensorStatusSupported: bits & (1 << 1) != 0,
            spotCheckStorageSupported: bits & (1 << 2) != 0,
            timestampSupported: bits & (1 << 3) != 0,
            fastMetricSupported: bits & (1 << 4) != 0,
            slowMetricSupported: bits & (1 << 5) != 0,
            pulseAmplitudeIndexSupported: bits & (1 << 6) != 0,
            multipleBondsSupported: bits & (1 << 7) != 0,
            raw: bits
        )
    }

    /// Compact summary of the enabled capabilities, e.g. `measStatus,devStatus,fast` (or `none`).
    public var shortDescription: String {
        var flags: [String] = []
        if measurementStatusSupported { flags.append("measStatus") }
        if deviceSensorStatusSupported { flags.append("devStatus") }
        if spotCheckStorageSupported { flags.append("storage") }
        if timestampSupported { flags.append("timestamp") }
        if fastMetricSupported { flags.append("fast") }
        if slowMetricSupported { flags.append("slow") }
        if pulseAmplitudeIndexSupported { flags.append("pai") }
        if multipleBondsSupported { flags.append("multiBond") }
        return flags.isEmpty ? "none" : flags.joined(separator: ",")
    }
}
