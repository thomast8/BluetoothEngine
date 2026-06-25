import Foundation

/// Link lifecycle for the single active peripheral session, surfaced by
/// `BLECentral.connectionStates()` so an app can show "connecting / connected / lost" without
/// polling. The engine does not auto-reconnect: after `.disconnected` the app decides whether to
/// call `connect` again (matching the manual flow the debug app already drives).
public enum ConnectionState: Sendable, Equatable {
    case connecting
    case connected
    /// The link dropped or never came up; `reason` carries the CoreBluetooth error text when present.
    case disconnected(reason: String?)
}
