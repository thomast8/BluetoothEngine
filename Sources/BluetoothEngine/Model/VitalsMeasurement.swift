import Foundation

/// Signal-quality summary derived from a parsed frame.
public enum SignalQuality: String, Sendable, Equatable, CaseIterable {
    case good
    case searching
    case lowPerfusion
    case noContact
    case unknown
}

/// One decoded reading from a vitals sensor — a pulse oximeter (SpO₂ + pulse rate) or a heart-rate
/// band (heart rate + RR-interval HRV). Each parser populates only the fields its profile carries,
/// so device-specific values are optional.
///
/// `contactDetected` is the generic sensor-contact signal: a finger on an oximeter, or a band worn
/// on the wrist. `spo2`/`pulseRate` are optional: a frame can be structurally valid yet carry no
/// usable number (sensor lost contact, still searching, or a sentinel like `0x7F`/`0xFF`).
/// `rrIntervalsMillis` carries
/// beat-to-beat intervals (HRV) in milliseconds when a heart-rate frame reports them, else nil —
/// including the degenerate case where the RR-present flag is set but no interval bytes remain
/// (e.g. a truncated payload), reported as nil rather than an empty array.
/// `raw` always carries the source bytes so even an undecoded frame can be dumped during
/// reverse-engineering.
public struct VitalsMeasurement: Sendable, Equatable {
    public var spo2: Double?
    public var pulseRate: Double?
    public var perfusionIndex: Double?
    public var plethRaw: Int?
    public var rrIntervalsMillis: [Double]?
    public var contactDetected: Bool
    public var quality: SignalQuality
    public var timestamp: Date
    public var raw: Data

    public init(
        spo2: Double? = nil,
        pulseRate: Double? = nil,
        perfusionIndex: Double? = nil,
        plethRaw: Int? = nil,
        rrIntervalsMillis: [Double]? = nil,
        contactDetected: Bool = false,
        quality: SignalQuality = .unknown,
        timestamp: Date = Date(),
        raw: Data = Data()
    ) {
        self.spo2 = spo2
        self.pulseRate = pulseRate
        self.perfusionIndex = perfusionIndex
        self.plethRaw = plethRaw
        self.rrIntervalsMillis = rrIntervalsMillis
        self.contactDetected = contactDetected
        self.quality = quality
        self.timestamp = timestamp
        self.raw = raw
    }
}
