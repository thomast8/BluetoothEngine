# BluetoothEngine — architecture map for agents

A small Swift 6 package for reading **BLE biometric sensors** — pulse oximeters (SpO₂ + pulse rate) and
heart-rate bands (HR + RR-interval HRV) — plus battery and device telemetry, on macOS/iOS, with a CLI
sniffer and a SwiftUI debug app. Read this before exploring — it is the fast path so you don't re-derive
the layering every session.

## Targets (`Package.swift`)

- **`BluetoothEngine`** — the library. Everything below lives here unless noted.
- **`sensor`** (`Sources/SensorCLI`) — CLI: `doctor` / `scan` / `discover` / `explore` / `raw` / `decode` / `info`.
- **`sensor-debug`** (`Sources/SensorDebugApp`) — SwiftUI debug GUI; streams every event over loopback
  SSE + JSONL (`SessionLogger`) so a session is observable without the GUI.
- **`BluetoothEngineTests`** (`Tests/`) — pure-function parser/stream/decoder tests (no CoreBluetooth).

## Layering (the one thing to internalize)

Transport is decoupled from decode. `BLECentral` knows nothing about pulse oximetry; it fans out raw
notifications and reads characteristics. Decoders are **pure, stateless** `Data → value?` transforms.
New domains (battery, device info) are added as new transforms/readers, never by adding state to the
transport or measurement model.

| Layer | File | Role |
|-------|------|------|
| Transport | `Sources/BluetoothEngine/BLECentral.swift` | `@MainActor` CoreBluetooth wrapper: scan / connect / inventory / subscribe / **raw-notification fan-out** (`notifications()`) / targeted reads / RSSI / connection-state. Delegate callbacks land on the main thread (`queue: nil`), satisfied via `@preconcurrency`. |
| GATT registry | `Model/KnownUUIDs.swift` | Known service/characteristic `CBUUID`s (computed, since `CBUUID` isn't `Sendable`) + `name(for:)`. |
| Parser seam | `Parsing/MeasurementParser.swift` | Protocol: `serviceUUID`, `characteristicUUIDs`, `parse(characteristic:value:) -> VitalsMeasurement?`. |
| PLX / HR decode | `Parsing/PLXSParser.swift`, `Parsing/HeartRateParser.swift`, `Parsing/SFLOAT.swift` | `PLXSParser`: standard PLX service `0x1822` (`0x2A5F` continuous / `0x2A5E` spot-check), IEEE-11073 SFLOAT. `HeartRateParser`: standard Heart Rate Service `0x180D` (`0x2A37`), incl. RR-intervals (HRV). |
| Measurement stream | `Parsing/MeasurementStream.swift` | `vitalsMeasurements(from:parser:)` — raw stream → measurements, drops undecodable frames. The template for all stream transforms. |
| Battery decode | `Parsing/BatteryDecoder.swift` | `BatteryDecoder.level(from:)` (`0x2A19`, one `UInt8` %) + `batteryLevels(from:)` stream transform. |
| Device info | `Parsing/DeviceInfoDecoder.swift`, `Model/DeviceInfo.swift` | DIS `0x180A` UTF-8 strings → `DeviceInfo`. |
| Capabilities | `Model/PLXFeatures.swift` | `0x2A60` Supported-Features bitfield → `PLXFeatures`. |
| Models | `Model/VitalsMeasurement.swift`, `Model/ConnectionState.swift`, `Model/BLEValueTypes.swift`, `Model/BLEError.swift` | Value types crossing the async boundary (all `Sendable`; UUIDs kept as strings). `VitalsMeasurement` is the shared SpO₂/PR/HR/RR reading; `contactDetected` is the generic sensor-contact flag. |
| Device registry | `SupportedDevices.swift` | What the engine can talk to: parser list, `serviceUUIDs`, advertised-hint `supports(_ peripheral:)` / `parser(forServiceUUIDs:)`, and the **authoritative** post-connection `parser(for: [ServiceInfo])` / `supports(_ services:)` that match a parser by service **or** characteristic. Engine declares capability; the app owns presentation/policy. |
| Supported-device probing | `SupportedDeviceScanner.swift` | `discoverSupported(using:probe:probeTimeout:scanWindow:) -> AsyncStream<SupportedDevice>` — the stack confirms support itself. Advertised-only by default (passive, never connects); opt-in `probe` also connects to connectable unknowns once (inventory → drop) and classifies via `parser(for:)`. Already-connected supported peripherals are surfaced via `BLECentral.connectedPeripherals` (`retrieveConnectedPeripherals`). `DeviceProbing` is the testable transport seam (`BLECentral` conforms); `SupportedDevice` carries the peripheral + `.advertised`/`.probed`/`.connected` confirmation + decoder name. |
| Consumers | `Sources/SensorCLI/SensorRunner.swift` (`scan` passive, `discover` confirmed), `Sources/SensorDebugApp/DebugModel.swift` | Reference integrations — copy these patterns. |

## Telemetry surfaces (battery + device info)

Non-measurement telemetry is **separate streams + one-shot reads**, kept off `VitalsMeasurement` so the
decode layer stays stateless. The app combines them in its view model (`DebugModel`).

- Battery: `central.readBatteryLevel() -> Int?` (initial) + `batteryLevels(from: central.notifications())`
  (live, when the device notifies `0x2A19`).
- Device info: `central.readDeviceInfo() -> DeviceInfo` (read-once).
- Capabilities: `central.readPLXFeatures() -> PLXFeatures?` (read-once).
- Link: `central.connectionStates() -> AsyncStream<ConnectionState>` (lifecycle; no auto-reconnect) and
  `central.readRSSI() -> Int?` (poll for live signal strength).
- `central.readCharacteristics([CBUUID]) -> [CBUUID: Data]` is the generic targeted read under all of the
  above; reuse it before adding a bespoke read path.

The raw-notification fan-out (`notifications()` returns a fresh stream per caller) is what lets
measurements, battery, and raw-hex listeners all consume the same notifications concurrently. Register
listeners **before** `subscribe(...)`. `subscribe(characteristics: nil)` enables notify on every
notifying characteristic (battery included); the CLI passes explicit targets and appends `0x2A19`.

## Build · test · run

```sh
swift build                                                          # or: make build  →  dist/sensor, dist/sensor-debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 80 pure-function tests
```

**Running against real hardware needs code signing.** A bare `swift run` **TCC-crashes (SIGABRT)** the
instant it touches CoreBluetooth — macOS won't honor the Bluetooth usage string for an unsigned binary.

```sh
bash scripts/make-debug-app.sh && open dist/SensorDebug.app       # ad-hoc-signed GUI in dist/; grant BT once
codesign --sign - "$(swift build --show-bin-path)/sensor"          # then: sensor info|explore|decode --name PM100
```

The Bluetooth grant attaches to the launching app/terminal, not the binary name.

## Reference devices

Verified against a **Medisana PM100** (rebadged ChoiceMMed MD300C208S) implementing the standard PLX
service — SpO₂/PR decode with no reverse-engineering, plus the standard Battery (`0x180F`) and Device
Information (`0x180A`) services the telemetry reads surface. Also verified against a **Whoop 5.0** in
Broadcast Heart Rate mode (standard HR service `0x180D`/`0x2A37`) — live HR + RR via `HeartRateParser`.
`Parsing/ProprietaryPM100Parser.swift` is an intentional stub (returns nil) kept as the fallback path
for non-standard devices; reverse-engineer it from `sensor raw --csv` captures.

## Conventions

- Keep transport dumb and decoders pure/stateless — add capability as new transforms, not new state.
- Models crossing the AsyncStream boundary must be `Sendable`; store UUIDs as strings (CoreBluetooth
  types aren't `Sendable`).
- New characteristics: add the UUID + name to `KnownUUIDs`, a pure decoder in `Parsing/`, and (if it
  streams) a transform mirroring `vitalsMeasurements` / `batteryLevels`.
- Note for the human: do not commit any `# GitNexus` block that `gitnexus analyze` injects here — strip
  it first.
