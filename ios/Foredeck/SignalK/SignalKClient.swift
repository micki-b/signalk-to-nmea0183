import Foundation
import Combine
import ForedeckCore

/// Optional read-only feed from the boat's Signal K server.
///
/// The payoff is accuracy, not decoration. A masthead or pushpit GPS knows
/// where the boat is considerably better than a phone in the pocket of someone
/// standing on the foredeck, so when the server is reachable its fix is the
/// better one to hang the anchor alarm on. Live depth while setting the hook is
/// the other half of it.
///
/// Everything degrades: no server, no problem, the app falls back to
/// CoreLocation and hides the instrument row.
@MainActor
final class SignalKClient: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var position: GeoPoint?
    @Published private(set) var depthBelowKeel: Double?
    @Published private(set) var depthBelowTransducer: Double?
    @Published private(set) var apparentWindSpeed: Double?
    @Published private(set) var apparentWindAngle: Double?
    @Published private(set) var speedOverGround: Double?
    @Published private(set) var updatedAt: Date?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempt = 0
    private var isStopping = false
    private var host: String = ""
    private var port: Int = 3000

    func connect(host: String, port: Int = 3000) {
        guard !host.isEmpty else { return }
        self.host = host
        self.port = port
        isStopping = false
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        isStopping = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        isConnected = false
    }

    private func openSocket() {
        guard !isStopping else { return }
        // subscribe=none, then ask for exactly the four paths we use. The
        // default firehose is a lot of JSON to parse on a phone that is also
        // running a voice codec.
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/signalk/v1/stream"
        components.queryItems = [URLQueryItem(name: "subscribe", value: "none")]

        guard let url = components.url else {
            lastError = "Could not build a Signal K URL for \(host)."
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task

        task.resume()
        sendSubscription()
        receiveNext()
    }

    private func sendSubscription() {
        let subscription: [String: Any] = [
            "context": "vessels.self",
            "subscribe": [
                ["path": "navigation.position", "period": 1_000],
                ["path": "environment.depth.belowKeel", "period": 1_000],
                ["path": "environment.depth.belowTransducer", "period": 1_000],
                ["path": "environment.wind.speedApparent", "period": 1_000],
                ["path": "environment.wind.angleApparent", "period": 1_000],
                ["path": "navigation.speedOverGround", "period": 1_000]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: subscription),
              let text = String(data: data, encoding: .utf8)
        else { return }

        task?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.handleFailure(error) }
        }
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.isConnected = true
                    self.reconnectAttempt = 0
                    self.lastError = nil
                    if case .string(let text) = message {
                        self.ingest(text)
                    } else if case .data(let data) = message,
                              let text = String(data: data, encoding: .utf8) {
                        self.ingest(text)
                    }
                    self.receiveNext()
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    private func handleFailure(_ error: Error) {
        guard !isStopping else { return }
        isConnected = false
        lastError = error.localizedDescription
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = pow(2.0, Double(reconnectAttempt))  // 2s .. 64s
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !self.isStopping else { return }
            self.openSocket()
        }
    }

    // MARK: - Delta parsing

    private func ingest(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updates = root["updates"] as? [[String: Any]]
        else { return }

        for update in updates {
            guard let values = update["values"] as? [[String: Any]] else { continue }
            for entry in values {
                guard let path = entry["path"] as? String else { continue }
                apply(path: path, value: entry["value"])
            }
        }
        updatedAt = Date()
    }

    private func apply(path: String, value: Any?) {
        switch path {
        case "navigation.position":
            if let dictionary = value as? [String: Any],
               let latitude = dictionary["latitude"] as? Double,
               let longitude = dictionary["longitude"] as? Double {
                position = GeoPoint(latitude: latitude, longitude: longitude)
            }
        case "environment.depth.belowKeel":
            depthBelowKeel = value as? Double
        case "environment.depth.belowTransducer":
            depthBelowTransducer = value as? Double
        case "environment.wind.speedApparent":
            apparentWindSpeed = value as? Double
        case "environment.wind.angleApparent":
            // Signal K is radians throughout; the UI converts once, here.
            if let radians = value as? Double {
                apparentWindAngle = radians * 180 / .pi
            }
        case "navigation.speedOverGround":
            speedOverGround = value as? Double
        default:
            break
        }
    }

    /// Best depth available, preferring below-keel because that is the number
    /// that decides whether you are aground.
    var depth: Double? { depthBelowKeel ?? depthBelowTransducer }
}
