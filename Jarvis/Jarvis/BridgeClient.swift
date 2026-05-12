import Foundation

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

    private(set) var port: Int = 0
    var onMessage: MessageHandler?
    var onStateChange: ((Bool) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1.0
    private let queue = DispatchQueue(label: "jarvis.bridge.client")
    private var stopped = true

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
        connect()
    }

    func stop() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
        guard let task = task else { return }
        do {
            let data = try JSONEncoder().encode(message)
            guard let str = String(data: data, encoding: .utf8) else { return }
            task.send(.string(str)) { error in
                if let error = error {
                    NSLog("[jarvis] bridge send failed: \(error.localizedDescription)")
                }
            }
        } catch {
            NSLog("[jarvis] bridge encode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard !stopped, port > 0 else { return }
        guard let url = URL(string: "ws://127.0.0.1:\(port)/") else { return }

        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(true) }
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
                NSLog("[jarvis] bridge recv failed: \(error.localizedDescription)")
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
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(decoded)
            }
        } catch {
            NSLog("[jarvis] bridge decode failed: \(error.localizedDescription)")
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(false) }
        guard !stopped else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.task = nil
            self?.connect()
        }
    }
}

extension BridgeClient: URLSessionDelegate, URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        reconnectDelay = 1.0
    }
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        scheduleReconnect()
    }
}
