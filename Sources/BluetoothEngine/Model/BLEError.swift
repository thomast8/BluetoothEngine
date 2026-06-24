import Foundation

/// Errors surfaced by the engine. `description` is operator-facing and is what the CLI prints to stderr.
public enum BLEError: Error, CustomStringConvertible, Equatable {
    case permissionDenied
    case poweredOff
    case unsupported
    case notConnected
    case deviceNotFound(query: String)
    case connectionFailed(reason: String)

    public var description: String {
        switch self {
        case .permissionDenied:
            return """
            Bluetooth permission is denied for the app running this terminal. Open System Settings \
            > Privacy & Security > Bluetooth and enable your terminal app, or run \
            `tccutil reset Bluetooth` and retry. The grant attaches to the terminal app, not to the binary.
            """
        case .poweredOff:
            return "Bluetooth is powered off. Turn it on and retry."
        case .unsupported:
            return "This machine reports no Bluetooth LE support."
        case .notConnected:
            return "Not connected to a peripheral."
        case .deviceNotFound(let query):
            return "No peripheral matched '\(query)' within the timeout."
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)."
        }
    }
}
