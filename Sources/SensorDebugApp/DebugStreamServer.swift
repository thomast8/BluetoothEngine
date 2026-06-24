import Foundation
import Network

/// A tiny loopback Server-Sent-Events server so an external observer can watch the debug session
/// live: `curl -N http://127.0.0.1:<port>/`. Every connected client receives each event as an SSE
/// `data: <json>` line. Bound to 127.0.0.1 only.
///
/// Built on the structured-concurrency Network API (`NetworkListener`/`NetworkConnection`, macOS/iOS
/// 26): all mutable connection state lives in the private `Core` actor, so this type is `Sendable`
/// without `@unchecked`. `broadcast` feeds an ordered `AsyncStream` drained by a single task in
/// `Core`, so the SSE event order matches submission order. A bind failure (e.g. the port is already
/// in use) is surfaced on stderr instead of failing silently.
final class DebugStreamServer: Sendable {
    /// The loopback port the SSE stream is served on. Immutable, so it is readable synchronously.
    nonisolated let port: UInt16
    private let core: Core
    private let events: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init(port: UInt16) {
        self.port = port
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation
        self.core = Core(port: port)
    }

    /// Begin listening and serving. Non-blocking.
    func start() {
        let core = core
        let events = events
        Task { await core.start(events: events) }
    }

    /// Broadcast one already-encoded JSON line to all connected clients as an SSE event.
    /// Ordered and non-blocking; safe to call from any thread/isolation.
    func broadcast(_ jsonLine: String) {
        continuation.yield(jsonLine)
    }

    /// Stop serving and tear down all live connections.
    func stop() {
        continuation.finish()
        let core = core
        Task { await core.stop() }
    }
}

/// Owns all mutable server state (the listener, the live-client set). Actor isolation is what lets
/// `DebugStreamServer` be `Sendable` without `@unchecked`.
private actor Core {
    private let port: UInt16
    private var clients: [ObjectIdentifier: NetworkConnection<TCP>] = [:]
    private var listenerTask: Task<Void, Never>?
    private var broadcastTask: Task<Void, Never>?

    init(port: UInt16) { self.port = port }

    func start(events: AsyncStream<String>) {
        guard listenerTask == nil else { return }
        listenerTask = Task { [weak self] in await self?.listen() }
        // A single consumer drains the ordered event stream and fans each line out to every client,
        // so SSE order matches submission order.
        broadcastTask = Task { [weak self] in
            for await line in events { await self?.send(line) }
        }
    }

    private func listen() async {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            report("invalid port \(port)")
            return
        }
        do {
            // Bind to loopback only: the local endpoint is 127.0.0.1 and the path is pinned to the
            // loopback interface, so the stream is never reachable off-box.
            let parameters = NWParametersBuilder<TCP>.parameters { TCP { IP() } }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: nwPort))
                .localEndpointReuseAllowed(true)
                .requiredInterfaceType(.loopback)
            let listener = try NetworkListener<TCP>(using: parameters)
                .onStateUpdate { [weak self] _, state in
                    // Surface a bind failure (e.g. port already in use) instead of silently never serving.
                    if case .failed(let error) = state { self?.report("listener failed: \(error)") }
                }
            // `run` starts a child subtask per incoming connection and returns only when cancelled.
            try await listener.run { [weak self] connection in
                await self?.serve(connection)
            }
        } catch {
            report("listener bind failed on port \(port): \(error)")
        }
    }

    /// Serve one connected client: send the SSE header + greeting, then keep the connection open
    /// (draining and discarding the incoming HTTP request) until the client disconnects.
    private func serve(_ connection: NetworkConnection<TCP>) async {
        // Bound concurrent observers so a pile of stuck clients can't grow unboundedly (loopback only).
        guard clients.count < 16 else { return }
        do {
            // No Access-Control-Allow-Origin: this is a loopback dev stream; we don't want arbitrary
            // local web pages reading device identifiers / health data cross-origin. `curl`/EventSource
            // on the same origin still work.
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            try await connection.send(Data(header.utf8))
            // Greet on connect so a freshly-attached client immediately sees a line (proves the pipe;
            // SSE otherwise only delivers events that occur after connection).
            try await connection.send(Data("data: {\"event\":\"stream_open\",\"port\":\(port)}\n\n".utf8))
            // Register only AFTER the header + greeting are framed. `Core` is a reentrant actor, so
            // registering earlier would let a concurrent `broadcast` interleave a `data:` frame into
            // (or ahead of) this connection's HTTP header and corrupt the SSE framing.
            let key = ObjectIdentifier(connection)
            clients[key] = connection
            defer { clients[key] = nil }
            // Keep the connection open; drain (and discard) the client's HTTP request. `receive`
            // throws when the client disconnects (or the task is cancelled), ending this subtask.
            while true {
                let received = try await connection.receive(atLeast: 1, atMost: 65536)
                if received.metadata.endOfStream { break }
            }
        } catch {
            // Client closed (curl exited) or a send failed — fall through to deregister.
        }
    }

    private func send(_ jsonLine: String) async {
        guard !clients.isEmpty else { return }
        let payload = Data("data: \(jsonLine)\n\n".utf8)
        // Fan out concurrently: a single slow/stuck client must not head-of-line-block delivery to
        // the others, nor stall the drain loop (which would silently drop events for everyone once
        // the buffer fills). Lines are still drained one at a time, so per-client order is preserved.
        await withTaskGroup(of: Void.self) { group in
            for connection in clients.values {
                group.addTask { try? await connection.send(payload) }
            }
        }
    }

    func stop() {
        // Cancelling the listener task tears down `listener.run` and every per-connection child
        // subtask (structured concurrency), which closes the live connections.
        listenerTask?.cancel(); listenerTask = nil
        broadcastTask?.cancel(); broadcastTask = nil
        clients.removeAll()
    }

    /// Surface an operational failure where an operator will actually see it.
    nonisolated private func report(_ message: String) {
        FileHandle.standardError.write(Data("DebugStreamServer: \(message)\n".utf8))
    }
}
