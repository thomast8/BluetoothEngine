import ArgumentParser
import BluetoothEngine
import Foundation

/// Shared option group: how to select the target peripheral (mirrors `AssetsOption`).
struct PeripheralSelector: ParsableArguments {
    @Option(name: .long, help: "Match peripheral by advertised name (case-insensitive substring).")
    var name: String?

    @Option(name: .long, help: "Match peripheral by CoreBluetooth identifier UUID (from `scan`).")
    var id: String?

    @Option(name: .long, help: "Seconds to wait for a match before giving up.")
    var timeout: Double = 15

    func match() throws -> PeripheralMatch {
        if let id {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("--id must be a UUID (got '\(id)')")
            }
            return .id(uuid)
        }
        if let name {
            return .name(name)
        }
        throw ValidationError("provide --name or --id to select a peripheral")
    }
}

/// Space-separated uppercase hex (`AA 55 62`) for a byte buffer.
func hexString(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// Printable-ASCII rendering of a byte buffer (non-printables as `.`), for `explore` reads.
func asciiString(_ data: Data) -> String {
    let chars = data.map { byte -> Character in
        (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    }
    return "\"" + String(chars) + "\""
}

enum CaptureLimits {
    static let defaultMaxBytes = 100 * 1024 * 1024
}

/// Install a SIGINT handler that runs `onInterrupt` on the main queue instead of terminating, so a
/// capture loop can finish its stream and flush. Keep the returned source alive for the loop's life.
@MainActor
func installInterruptHandler(_ onInterrupt: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { onInterrupt() }
    source.resume()
    return source
}

/// Appends capture lines to a file, flushing + fsyncing on close so a Ctrl-C'd capture is valid.
final class CaptureWriter {
    private let handle: FileHandle
    private let maxBytes: Int
    private var bytesWritten = 0
    private var limitReported = false
    let path: String

    init(path: String, header: String?, maxBytes: Int = CaptureLimits.defaultMaxBytes) throws {
        self.path = path
        self.maxBytes = maxBytes
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw BLEError.connectionFailed(reason: "cannot open \(path) for writing")
        }
        self.handle = handle
        if let header { write(header) }
    }

    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        guard bytesWritten + data.count <= maxBytes else {
            if !limitReported {
                limitReported = true
                FileHandle.standardError.write(Data(
                    "warning: capture \(path) reached \(maxBytes) bytes; dropping later frames\n".utf8
                ))
            }
            return
        }
        handle.write(data)
        bytesWritten += data.count
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }
}
