import Foundation
import os.log

/// Wire payload for messages flowing between Jarvis.app and the
/// Python Telethon bridge. We keep the schema tiny and string-keyed
/// so the bridge can decode it with stdlib `json` alone.
struct BridgeMessage: Codable {
    let kind: String
    let text: String?
    let hasMedia: Bool?
    let mediaCaption: String?
    let timestamp: Double?
    let data: [String: AnyCodable]?
    let pngBase64: String?
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case text
        case hasMedia = "has_media"
        case mediaCaption = "media_caption"
        case timestamp
        case data
        case pngBase64 = "png_base64"
        case caption
    }
}

/// Minimal Any-codable shim so we can round-trip arbitrary JSON values
/// inside the `data` field (heartbeats include strings, ints, floats, bools).
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull() }
        else if let b = try? c.decode(Bool.self) { self.value = b }
        else if let i = try? c.decode(Int.self) { self.value = i }
        else if let d = try? c.decode(Double.self) { self.value = d }
        else if let s = try? c.decode(String.self) { self.value = s }
        else if let a = try? c.decode([AnyCodable].self) { self.value = a.map { $0.value } }
        else if let o = try? c.decode([String: AnyCodable].self) {
            self.value = o.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}

/// URLSession-backed websocket client that talks to the local Python bridge
/// on `ws://127.0.0.1:<port>/`. Reconnects on failure with bounded backoff.
final class BridgeClient: NSObject {
    typealias MessageHandler = (BridgeMessage) -> Void

    enum State: String {
        case idle           // never started, or stop() called
        case connecting     // task resumed, handshake pending
        case connected      // didOpenWithProtocol fired — wire is live
        case disconnected   // closed; reconnect pending
    }

    private(set) var port: Int = 0
    private(set) var state: State = .idle
    var agentSlug: String = Trace.unknownAgent
    var onMessage: MessageHandler?
    var onStateChange: ((Bool) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1.0
    private let queue = DispatchQueue(label: "jarvis.bridge.client")
    private var stopped = true
    /// Outbound messages that arrived before the websocket handshake
    /// completed. Flushed in `didOpenWithProtocol`. Bounded so a stuck
    /// connection can't unboundedly grow memory.
    private var pendingOutbound: [BridgeMessage] = []
    private static let pendingCap = 32

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        self.session = URLSession(configuration: cfg,
                                  delegate: self,
                                  delegateQueue: nil)
    }

    func start(port: Int) {
        self.port = port
        self.stopped = false
        Trace.log(Trace.bridge, agent: agentSlug,
                  "client.start(port=\(port))")
        if port <= 0 {
            // Used to silently fall through into `connect()` which
            // early-returned without surfacing the failure — sends then
            // disappeared into a nil `task`. Make the dead state explicit
            // so the user sees "disconnected" in the tray and the trace.
            Trace.log(Trace.bridge, .error, agent: agentSlug,
                      "start refused — port=\(port). Bridge subprocess "
                      + "did not announce a port; outbound traffic would "
                      + "be silently dropped.")
            state = .disconnected
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(false) }
            return
        }
        connect()
    }

    func stop() {
        Trace.log(Trace.bridge, agent: agentSlug, "client.stop()")
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
        pendingOutbound.removeAll()
    }

    // MARK: - Sending

    func sendText(_ text: String) {
        send(.init(kind: "user_text", text: text, hasMedia: nil, mediaCaption: nil,
                   timestamp: Date().timeIntervalSince1970, data: nil,
                   pngBase64: nil, caption: nil))
    }

    func sendHeartbeat(_ payload: [String: Any]) {
        let coded = payload.mapValues(AnyCodable.init)
        send(.init(kind: "heartbeat", text: nil, hasMedia: nil, mediaCaption: nil,
                   timestamp: Date().timeIntervalSince1970,
                   data: coded, pngBase64: nil, caption: nil))
    }

    func sendScreenshot(pngBase64: String, caption: String) {
        send(.init(kind: "screenshot", text: nil, hasMedia: nil, mediaCaption: nil,
                   timestamp: Date().timeIntervalSince1970,
                   data: nil,
                   pngBase64: pngBase64, caption: caption))
    }

    private func send(_ message: BridgeMessage) {
        Trace.log(Trace.bridge, agent: agentSlug,
                  "send kind=\(message.kind) state=\(state.rawValue)")
        switch state {
        case .connected:
            transmit(message)
        case .connecting:
            // Handshake hasn't completed yet. URLSession would buffer the
            // send and either flush on success or drop it on failure with
            // no visible error. Hold the payload here instead and flush
            // explicitly from `didOpenWithProtocol`.
            if pendingOutbound.count >= BridgeClient.pendingCap {
                Trace.log(Trace.bridge, .error, agent: agentSlug,
                          "pending buffer full (\(BridgeClient.pendingCap)) — "
                          + "dropping oldest kind=\(pendingOutbound.first?.kind ?? "?")")
                pendingOutbound.removeFirst()
            }
            pendingOutbound.append(message)
            Trace.log(Trace.bridge, agent: agentSlug,
                      "queued kind=\(message.kind) pending=\(pendingOutbound.count)")
        case .idle, .disconnected:
            Trace.log(Trace.bridge, .error, agent: agentSlug,
                      "DROP kind=\(message.kind) — state=\(state.rawValue)")
        }
    }

    private func transmit(_ message: BridgeMessage) {
        guard let task = task else {
            Trace.log(Trace.bridge, .error, agent: agentSlug,
                      "transmit kind=\(message.kind) — task is nil despite "
                      + "state=\(state.rawValue) (logic error)")
            return
        }
        do {
            let data = try JSONEncoder().encode(message)
            guard let str = String(data: data, encoding: .utf8) else { return }
            let slug = agentSlug
            let kind = message.kind
            task.send(.string(str)) { error in
                if let error = error {
                    Trace.log(Trace.bridge, .error, agent: slug,
                              "send completion error kind=\(kind): "
                              + "\(error.localizedDescription)")
                } else {
                    Trace.log(Trace.bridge, agent: slug,
                              "send completion ok kind=\(kind) bytes=\(str.utf8.count)")
                }
            }
        } catch {
            Trace.log(Trace.bridge, .error, agent: agentSlug,
                      "encode failed kind=\(message.kind): \(error.localizedDescription)")
        }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard !stopped else {
            Trace.log(Trace.bridge, agent: agentSlug,
                      "connect() skipped — stopped")
            return
        }
        guard port > 0 else {
            Trace.log(Trace.bridge, .error, agent: agentSlug,
                      "connect() skipped — port=\(port)")
            return
        }
        guard let url = URL(string: "ws://127.0.0.1:\(port)/") else { return }

        Trace.log(Trace.bridge, agent: agentSlug,
                  "connect ws://127.0.0.1:\(port)/")
        state = .connecting
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        // NOTE: onStateChange(true) used to fire here, before the
        // handshake actually completed. That meant the tray icon said
        // "connected" while sends were silently buffered into a TCP
        // connection that hadn't been negotiated yet. State updates now
        // come from `didOpenWithProtocol` instead.
        listen()
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message: message)
                self.listen()
            case .failure(let error):
                Trace.log(Trace.bridge, .error, agent: self.agentSlug,
                          "recv failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let payload: Data?
        switch message {
        case .data(let d): payload = d
        case .string(let s): payload = s.data(using: .utf8)
        @unknown default: payload = nil
        }
        guard let data = payload else { return }
        do {
            let decoded = try JSONDecoder().decode(BridgeMessage.self, from: data)
            Trace.log(Trace.bridge, agent: agentSlug,
                      "recv kind=\(decoded.kind)")
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(decoded)
            }
        } catch {
            Trace.log(Trace.bridge, .error, agent: agentSlug,
                      "decode failed: \(error.localizedDescription)")
        }
    }

    private func scheduleReconnect() {
        let wasConnected = (state == .connected)
        state = .disconnected
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(false) }
        guard !stopped else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        Trace.log(Trace.bridge, agent: agentSlug,
                  "reconnect scheduled in \(delay)s wasConnected=\(wasConnected)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.task = nil
            self?.connect()
        }
    }

    private func flushPending() {
        guard !pendingOutbound.isEmpty else { return }
        let drained = pendingOutbound
        pendingOutbound.removeAll()
        Trace.log(Trace.bridge, agent: agentSlug,
                  "flushing \(drained.count) queued message(s)")
        for msg in drained { transmit(msg) }
    }
}

extension BridgeClient: URLSessionDelegate, URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        reconnectDelay = 1.0
        state = .connected
        Trace.log(Trace.bridge, agent: agentSlug,
                  "didOpenWithProtocol — handshake complete, port=\(port)")
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(true) }
        flushPending()
    }
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        Trace.log(Trace.bridge, agent: agentSlug,
                  "didCloseWith code=\(closeCode.rawValue)")
        scheduleReconnect()
    }
}
