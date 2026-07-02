# BluetoothEngine

A small, focused Swift package for reading **Bluetooth LE biometric sensors** — pulse oximeters
(SpO₂ + pulse rate) and heart-rate bands (heart rate + RR-interval HRV) — plus **battery level** and
**device telemetry**, on macOS and iOS, with a CLI sniffer and a SwiftUI debug app. A reusable
standalone biofeedback input for breath-hold / apnea training.

## Layout

- **`BluetoothEngine`** (library) — a `@MainActor` `BLECentral` over CoreBluetooth with `AsyncStream`
  feeds (scan / connect / inventory / notifications) and a pluggable `MeasurementParser` seam.
  `PLXSParser` decodes the standard Bluetooth SIG Pulse Oximeter Service (`0x1822`, IEEE-11073 SFLOAT);
  `HeartRateParser` decodes the standard Heart Rate Service (`0x180D` / Heart Rate Measurement `0x2A37`),
  including beat-to-beat RR-intervals (HRV). Non-measurement **telemetry** rides alongside as separate
  streams + one-shot reads — battery level (`readBatteryLevel()` + `batteryLevels(from:)`), `DeviceInfo`
  (`0x180A`), `PLXFeatures` (`0x2A60`), link `connectionStates()` and `readRSSI()` — kept off
  `VitalsMeasurement` so decoders stay stateless. `SupportedDevices` declares what the engine can talk
  to (so an app can scan filtered to compatible devices instead of listing every AirPod in the room).
  Support is judged **structurally** against the registered parsers — a device matches if its GATT
  exposes a service *or* characteristic any parser decodes (`SupportedDevices.parser(for:)`), so a new
  device is recognised by structure, never by a hard-coded name/model. `discoverSupported(using:)` puts
  this in the stack: by default it surfaces devices that *advertise* a known service (a passive scan that
  never connects); an opt-in `probe` mode additionally connects to connectable unknowns (read GATT →
  drop) to confirm a device whose advertisement omits its service, and already-connected devices are
  surfaced too. The engine declares capability; the app owns presentation/policy.
- **`sensor`** (CLI) — `doctor` / `scan` (passive: every BLE device) / `discover` (only devices the
  engine can decode, probing unknowns to confirm) / `explore` / `raw` (timestamped hex + CSV capture) /
  `decode` (SpO₂ + pulse rate, plus heart rate + RR-intervals for HR bands, and live battery) / `info`
  (read-once device info, PLX features, battery, RSSI).
- **`sensor-debug`** (SwiftUI app) — scan/connect, live decoded SpO₂/PR (+ HR/RR), battery + device
  telemetry, raw hex log, GATT tree. Streams every event over loopback SSE (`http://127.0.0.1:8787/`)
  and to `~/Library/Logs/SensorDebug/session.jsonl`, so a session is observable live without reading the GUI.

## Build & test

```sh
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Running the BLE tools (important: code signing)

A **bare `swift run` binary TCC-crashes** (SIGABRT) the instant it touches CoreBluetooth — macOS won't
honor the embedded Bluetooth usage string unless the binary is **code-signed**. Use the bundled app:

```sh
bash scripts/make-debug-app.sh     # builds + ad-hoc-signs ./SensorDebug.app (at the repo root)
open SensorDebug.app               # grant the one-time Bluetooth prompt, then Scan/connect
```

The Bluetooth permission grant attaches to the launching app/terminal, not to the binary name. To run
the `sensor` CLI against hardware, ad-hoc sign it too: `codesign --sign - "$(swift build --show-bin-path)/sensor"`.

## Status

Verified against a real **Medisana PM100** (a rebadged ChoiceMMed MD300C208S) which implements the
standard PLX service — SpO₂ + pulse rate decode out of the box, no reverse-engineering needed. It also
exposes the standard Battery (`0x180F`) and Device Information (`0x180A`) services, which the telemetry
reads surface.

Also verified against a real **Whoop 5.0** in **Broadcast Heart Rate** mode, which exposes the
standard Heart Rate Service (`0x180D` / `0x2A37`) — live heart rate + RR-intervals decode out of the
box via `HeartRateParser`. Whoop's other metrics (strain, recovery, SpO₂, raw PPG) ride a proprietary
encrypted service and are out of scope for the standard-profile path.
