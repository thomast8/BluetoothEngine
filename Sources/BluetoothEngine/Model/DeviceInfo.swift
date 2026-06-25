import Foundation

/// Read-once identity from the standard Device Information Service (`0x180A`).
///
/// Every field is optional because the service is itself optional and a device may expose only a
/// subset of the characteristics. All are UTF-8 strings; this is identity/labelling data, not a
/// streaming measurement, so it is read once on connect rather than fanned out as notifications.
public struct DeviceInfo: Sendable, Equatable {
    public var manufacturerName: String?
    public var modelNumber: String?
    public var serialNumber: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    public var softwareRevision: String?

    public init(
        manufacturerName: String? = nil,
        modelNumber: String? = nil,
        serialNumber: String? = nil,
        firmwareRevision: String? = nil,
        hardwareRevision: String? = nil,
        softwareRevision: String? = nil
    ) {
        self.manufacturerName = manufacturerName
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
        self.softwareRevision = softwareRevision
    }

    /// Whether the service yielded nothing readable (so callers can treat "no DIS" distinctly).
    public var isEmpty: Bool {
        manufacturerName == nil && modelNumber == nil && serialNumber == nil
            && firmwareRevision == nil && hardwareRevision == nil && softwareRevision == nil
    }
}
