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
                    if model.isSupported(device) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .help("Supported: advertises a service the engine can decode")
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.visibleDevices.isEmpty {
                ContentUnavailableView(
                    model.supportedOnly ? "No supported devices" : "No devices",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(model.supportedOnly
                        ? "No compatible oximeter nearby. Turn off “Supported only” to see all BLE devices."
                        : "Press Scan to look for nearby BLE peripherals.")
                )
            }
        }
    }

    // MARK: Detail — readout + live hex + GATT tree

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            readout
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
            Label("Connected to \(model.connectedName ?? "device")", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private var readout: some View {
        HStack(spacing: 32) {
            metric("SpO₂", model.latest?.spo2.map { String(format: "%.0f%%", $0) } ?? "—")
            metric("Pulse", model.latest?.pulseRate.map { String(format: "%.0f", $0) } ?? "—", unit: "bpm")
            metric("RR", model.latestRRMillis?.last.map { String(format: "%.0f", $0) } ?? "—", unit: "ms")
            VStack(alignment: .leading) {
                Text("contact \(model.latest?.contactDetected == true ? "yes" : "no")")
                Text("quality \(model.latest?.quality.rawValue ?? "—")")
            }
            .font(.callout).foregroundStyle(.secondary)
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

            Toggle("Supported only", isOn: $model.supportedOnly)
                .toggleStyle(.switch)
                .help("Show only peripherals the engine can decode (advertise a supported service)")

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
