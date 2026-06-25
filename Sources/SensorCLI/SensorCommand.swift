import ArgumentParser
import BluetoothEngine
import Foundation

/// Root command for the BLE pulse-oximeter sniffer / protocol explorer.
@main
struct SensorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sensor",
        abstract: "Bluetooth LE pulse-oximeter sniffer and protocol explorer.",
        discussion: """
        Reverse-engineering tooling for BLE oximeters (e.g. Medisana PM100). Typical flow: \
        `doctor` (grant Bluetooth) → `scan` (list everything) or `discover` (only devices the engine \
        can decode) → `explore` (map its GATT) → `raw --csv` (capture frames) → `decode` (parse live). \
        The Bluetooth permission prompt is attributed to the terminal app running `sensor`, not to \
        `sensor` itself.
        """,
        subcommands: [Doctor.self, Scan.self, Discover.self, Explore.self, Raw.self, Decode.self, Info.self],
        defaultSubcommand: Scan.self
    )
}

/// Print a BLEError's operator-facing description to stderr and exit non-zero.
private func failing(_ error: Error) -> Error {
    let message = (error as? BLEError)?.description ?? "\(error)"
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    return ExitCode.failure
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check Bluetooth permission and power state, and print remediation."
    )

    func run() async throws {
        let central = await BLECentral.make()
        // Let CoreBluetooth settle its initial state before reading it.
        try? await Task.sleep(for: .milliseconds(400))
        let auth = await central.authorizationDescription
        let state = await central.stateDescription
        let ready = await central.isPoweredOn

        print("Bluetooth authorization: \(auth)")
        print("Bluetooth state:         \(state)")
        if ready {
            print("\nReady. Try: breath sensor scan")
        } else {
            print("""

            Not ready.
            - If authorization is denied/restricted: System Settings > Privacy & Security > Bluetooth,
              enable your terminal app — or run `tccutil reset Bluetooth` and re-run (this resets every
              app's Bluetooth grant). The grant attaches to the terminal app, not to `breath`.
            - If state is poweredOff: turn Bluetooth on.
            """)
        }
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "List nearby BLE peripherals until Ctrl-C."
    )

    @Option(name: .long, help: "Only show peripherals whose name contains this (case-insensitive).")
    var name: String?

    func run() async throws {
        do {
            try await SensorRunner.scan(nameFilter: name)
        } catch {
            throw failing(error)
        }
    }
}

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "List devices the engine can decode (those advertising a supported service)."
    )

    @Flag(name: .long, help: "Also connect to unknown peripherals to confirm support. Intrusive: reaches out to nearby devices and can trigger pairing prompts.")
    var probe: Bool = false

    @Option(name: .long, help: "Seconds to wait when probing an unknown peripheral (with --probe).")
    var probeTimeout: Double = 6

    @Option(name: .long, help: "Seconds per scan window between probes (with --probe).")
    var scanWindow: Double = 4

    func run() async throws {
        do {
            try await SensorRunner.discover(probe: probe, probeTimeout: probeTimeout, scanWindow: scanWindow)
        } catch {
            throw failing(error)
        }
    }
}

struct Explore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explore",
        abstract: "Connect and print the full GATT service/characteristic tree."
    )

    @OptionGroup var selector: PeripheralSelector

    @Flag(name: .long, help: "Emit the service tree as JSON instead of a text tree.")
    var json: Bool = false

    func run() async throws {
        do {
            try await SensorRunner.explore(match: try selector.match(), timeout: selector.timeout, json: json)
        } catch {
            throw failing(error)
        }
    }
}

struct Raw: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raw",
        abstract: "Subscribe to every notifying characteristic and stream timestamped hex."
    )

    @OptionGroup var selector: PeripheralSelector

    @Flag(name: .long, help: "Emit CSV (t_mono_s,t_wall_iso,char_uuid,len,hex) — the fixture source of record.")
    var csv: Bool = false

    @Option(name: .shortAndLong, help: "Write capture to this file (flushed on Ctrl-C). If omitted, prints to stdout.")
    var out: String?

    @Option(name: .long, help: "Limit to these characteristic UUIDs (repeatable). Default: all notifying chars.")
    var char: [String] = []

    func run() async throws {
        do {
            try await SensorRunner.raw(
                match: try selector.match(),
                timeout: selector.timeout,
                csv: csv,
                out: out,
                chars: char.isEmpty ? nil : char
            )
        } catch {
            throw failing(error)
        }
    }
}

struct Decode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "Parse measurements live (standard PLXS now; proprietary once implemented)."
    )

    @OptionGroup var selector: PeripheralSelector

    @Option(name: .long, help: "Parser to use: auto | plxs | hrs | proprietary.")
    var service: String = "auto"

    func run() async throws {
        do {
            try await SensorRunner.decode(match: try selector.match(), timeout: selector.timeout, service: service)
        } catch {
            throw failing(error)
        }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Connect and print read-once telemetry: device info, PLX features, battery, RSSI."
    )

    @OptionGroup var selector: PeripheralSelector

    func run() async throws {
        do {
            try await SensorRunner.info(match: try selector.match(), timeout: selector.timeout)
        } catch {
            throw failing(error)
        }
    }
}
