import BluetoothEngine
import SwiftUI

struct ContentView: View {
    @State private var model = DebugModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .onAppear { model.refreshAuthorization() }
    }

    // MARK: Sidebar — scan results

    private var sidebar: some View {
        List(model.visibleDevices, id: \.id) { device in
            Button {
                model.connect(to: device)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name ?? "(no name)").fontWeight(.medium)
                        Text("rssi \(device.rssi)  ·  \(device.isConnectable ? "connectable" : "non-conn")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(device.id.uuidString).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    if device.id == model.connectedDevice?.id {
                        Image(systemName: "link.circle.fill")
                            .foregroundStyle(.blue)
                            .help("Connected — click another device to switch")
                    }
                    if let info = model.supportInfo(for: device.id) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .help("Confirmed via \(info.confirmation.label) — decoder \(info.decoderName)")
                    } else if model.showAllPassive, model.isSupported(device) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(.green)
                            .help("Advertises a service the engine can decode (hint — connect to confirm)")
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.visibleDevices.isEmpty {
                ContentUnavailableView(
                    model.showAllPassive ? "No devices" : "No supported devices",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(model.showAllPassive
                        ? "Press Scan to look for nearby BLE peripherals."
                        : "Scanning and probing for devices the engine can decode. Turn on “Show all” to see every BLE device.")
                )
            }
        }
    }

    // MARK: Detail — readout + live hex + GATT tree

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            readout
            telemetry
            Divider()
            HStack(alignment: .top, spacing: 16) {
                logView
                gattView
            }
            Spacer()
            footer
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.phase {
        case .idle:
            Text("Idle — auth: \(model.authorization)").foregroundStyle(.secondary)
        case .scanning:
            Label("Scanning…", systemImage: "dot.radiowaves.left.and.right")
        case .connecting:
            Label("Connecting to \(model.connectedName ?? "device")…", systemImage: "link")
        case .connected:
            Label(
                "Connected to \(model.connectedName ?? "device")"
                    + (model.connectedDecoder.map { " · decodable: \($0)" } ?? " · not decodable")
                    + (model.dataStale ? " · no data" : ""),
                systemImage: model.dataStale ? "exclamationmark.circle" : "checkmark.seal"
            )
            .foregroundStyle(model.dataStale ? .orange : .green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private var readout: some View {
        // When the link is up but streaming has stopped (dataStale), blank the values rather than leave
        // the last reading frozen on screen — a frozen number reads as "live".
        let m = model.dataStale ? nil : model.latest
        let rr = model.dataStale ? nil : model.latestRRMillis
        return HStack(spacing: 32) {
            metric("SpO₂", m?.spo2.map { String(format: "%.0f%%", $0) } ?? "—")
            metric("Pulse", m?.pulseRate.map { String(format: "%.0f", $0) } ?? "—", unit: "bpm")
            metric("RR", rr?.last.map { String(format: "%.0f", $0) } ?? "—", unit: "ms")
            VStack(alignment: .leading) {
                Text("contact \(m?.contactDetected == true ? "yes" : "no")")
                Text("quality \(m?.quality.rawValue ?? "—")")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Device telemetry row: battery / link / identity / capabilities, shown once connected.
    @ViewBuilder private var telemetry: some View {
        if model.phase == .connected {
            HStack(spacing: 20) {
                // Battery — prominent, with a level-aware icon so it reads as a real indicator.
                HStack(spacing: 6) {
                    Image(systemName: batterySymbol(model.battery))
                        .imageScale(.large)
                        .foregroundStyle(batteryColor(model.battery))
                    Text(model.battery.map { "\($0)%" } ?? "—")
                        .font(.title3).fontWeight(.medium).monospacedDigit()
                }
                .help("Battery level (Battery Service 0x2A19)")

                Divider().frame(height: 30)

                label("Link", model.rssi.map { "\($0) dBm" } ?? "—")
                if let info = model.deviceInfo {
                    label("Device", [info.manufacturerName, info.modelNumber]
                        .compactMap { $0 }.joined(separator: " "))
                    if let fw = info.firmwareRevision { label("Firmware", fw) }
                }
                if let features = model.features {
                    label("PLX", features.shortDescription)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// SF Symbol for a battery level (nil → empty outline).
    private func batterySymbol(_ level: Int?) -> String {
        switch level {
        case .none: return "battery.0"
        case .some(let l) where l < 13: return "battery.0"
        case .some(let l) where l < 38: return "battery.25"
        case .some(let l) where l < 63: return "battery.50"
        case .some(let l) where l < 88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryColor(_ level: Int?) -> Color {
        guard let level else { return .secondary }
        if level < 20 { return .red }
        if level < 40 { return .orange }
        return .green
    }

    private func label(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }

    private func metric(_ title: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                Button("Clear", action: model.clearLog).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.log.suffix(200)) { line in
                        Text("\(String(format: "%7.2f", line.monotonic))  \(line.characteristic)  \(line.hex)")
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 320, minHeight: 240)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var gattView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GATT").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.services, id: \.uuid) { service in
                        Text("\(service.uuid)\(service.knownName.map { " (\($0))" } ?? "")")
                            .font(.system(.caption, design: .monospaced)).fontWeight(.medium)
                        ForEach(service.characteristics, id: \.uuid) { ch in
                            Text("  \(ch.uuid) [\(ch.properties.shortDescription)]\(ch.knownName.map { " \($0)" } ?? "")")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 280, minHeight: 240)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("live stream:  curl -N \(model.streamURL)")
            Text("log file:  \(model.logPath)")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Parser", selection: $model.parserChoice) {
                ForEach(DebugModel.ParserChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Which decoder to apply to incoming frames")

            Toggle("Show all", isOn: $model.showAllPassive)
                .toggleStyle(.switch)
                .help("Show every BLE device (passive scan) instead of only engine-confirmed ones")
                .onChange(of: model.showAllPassive) {
                    if model.phase == .scanning { model.startScan() }
                }

            Toggle("Probe", isOn: $model.probeUnknowns)
                .toggleStyle(.switch)
                .help("Also connect to unknown devices to confirm support — intrusive, may trigger pairing prompts. Off by default; sensors that advertise their service are found without it.")
                .disabled(model.showAllPassive)
                .onChange(of: model.probeUnknowns) {
                    if model.phase == .scanning { model.startScan() }
                }

            if model.phase == .scanning {
                Button("Stop", systemImage: "stop.fill", action: model.stopScan)
            } else {
                Button("Scan", systemImage: "dot.radiowaves.left.and.right", action: model.startScan)
            }
            Button("Disconnect", systemImage: "xmark.circle", action: model.disconnect)
                .disabled(model.phase != .connected && model.phase != .connecting)
        }
    }
}
