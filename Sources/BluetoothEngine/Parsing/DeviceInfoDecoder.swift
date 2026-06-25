import CoreBluetooth
import Foundation

/// Builds a `DeviceInfo` from raw Device Information Service characteristic values.
///
/// Pure (`[CBUUID: Data]` in, value out) so it can be unit-tested without CoreBluetooth, mirroring
/// the `MeasurementParser` design. The map is what `BLECentral.readCharacteristics(_:)` returns.
public enum DeviceInfoDecoder {
    public static func decode(_ values: [CBUUID: Data]) -> DeviceInfo {
        func string(_ uuid: CBUUID) -> String? {
            guard let data = values[uuid], !data.isEmpty else { return nil }
            // DIS strings are UTF-8; trim trailing NULs some firmwares pad with, plus whitespace.
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
            return text.isEmpty ? nil : text
        }
        return DeviceInfo(
            manufacturerName: string(KnownUUIDs.manufacturerName),
            modelNumber: string(KnownUUIDs.modelNumber),
            serialNumber: string(KnownUUIDs.serialNumber),
            firmwareRevision: string(KnownUUIDs.firmwareRevision),
            hardwareRevision: string(KnownUUIDs.hardwareRevision),
            softwareRevision: string(KnownUUIDs.softwareRevision)
        )
    }

    /// The DIS characteristic UUIDs this decoder reads — pass to `readCharacteristics(_:)`.
    public static var characteristicUUIDs: [CBUUID] {
        [
            KnownUUIDs.manufacturerName, KnownUUIDs.modelNumber, KnownUUIDs.serialNumber,
            KnownUUIDs.firmwareRevision, KnownUUIDs.hardwareRevision, KnownUUIDs.softwareRevision,
        ]
    }
}
