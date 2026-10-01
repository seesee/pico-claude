import Foundation
import Network
import PicoClaudeCore

/// Small MQTT client on Network.framework: subscribes, publishes at QoS 0,
/// pings, and reconnects by itself. All callbacks arrive on the main queue.
final class MQTTClient {
    struct Endpoint: Equatable {
        var host: String
        var port: Int
    }

    var onMessage: ((String, Data) -> Void)?
    /// (connected, problem description if not)
    var onState: ((Bool, String?) -> Void)?

    private let queue = DispatchQueue(label: "pico-claude.mqtt")
    private let clientID: String
    private let topics: [String]
    private var endpoint: Endpoint?
    private var connection: NWConnection?
    private var decoder = MQTT.Decoder()
    private var connected = false
    private var lastReceive = Date()
    private var timer: DispatchSourceTimer?
    private var generation = 0     // ignores callbacks from connections we gave up on

    init(clientID: String, topics: [String]) {
        self.clientID = clientID
        self.topics = topics
    }

    func start(_ endpoint: Endpoint) {
        queue.async {
            self.endpoint = endpoint
            self.connect()
            if self.timer == nil {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now() + 10, repeating: 10)
                t.setEventHandler { self.tick() }   // the client lives as long as the app
                t.resume()
                self.timer = t
            }
        }
    }

    func publish(topic: String, payload: Data, retain: Bool) {
        queue.async {
            guard self.connected else { return }
            self.connection?.send(content: MQTT.publish(topic: topic, payload: payload, retain: retain),
                                  completion: .contentProcessed { _ in })
        }
    }

    // MARK: - connection lifecycle (all on `queue`)

    private func connect() {
        drop(reason: nil)
        guard let endpoint, let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else { return }
        generation += 1
        let gen = generation
        decoder = MQTT.Decoder()
        lastReceive = Date()
        let conn = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                conn.send(content: MQTT.connect(clientID: self.clientID), completion: .contentProcessed { _ in })
                self.receive(conn, gen)
            case .waiting(let error):
                // Typically "no route": broker down, or macOS Local Network access not granted.
                self.report(false, Self.describe(error))
            case .failed(let error):
                self.drop(reason: Self.describe(error))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, _ gen: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, gen == self.generation else { return }
            if let data, !data.isEmpty {
                self.lastReceive = Date()
                for packet in self.decoder.feed(data) { self.handle(packet, conn) }
            }
            if done || error != nil {
                self.drop(reason: error.map(Self.describe) ?? "broker closed the connection")
                return
            }
            self.receive(conn, gen)
        }
    }

    private func handle(_ packet: MQTT.Packet, _ conn: NWConnection) {
        if packet.type == 2 {   // CONNACK
            guard packet.body.count >= 2, packet.body[1] == 0 else {
                drop(reason: "broker refused the connection")
                return
            }
            conn.send(content: MQTT.subscribe(topics: topics), completion: .contentProcessed { _ in })
            connected = true
            report(true, nil)
        } else if let message = MQTT.message(from: packet) {
            DispatchQueue.main.async { self.onMessage?(message.topic, message.payload) }
        }
    }

    /// Every 10s: ping a live connection, retry a dead one.
    private func tick() {
        if connected {
            if Date().timeIntervalSince(lastReceive) > 90 {
                drop(reason: "broker stopped responding")
                connect()
            } else {
                connection?.send(content: MQTT.pingRequest, completion: .contentProcessed { _ in })
            }
        } else if connection == nil || Date().timeIntervalSince(lastReceive) > 20 {
            connect()
        }
    }

    private func drop(reason: String?) {
        generation += 1
        connection?.cancel()
        connection = nil
        if connected || reason != nil {
            connected = false
            report(false, reason)
        }
    }

    private func report(_ up: Bool, _ problem: String?) {
        DispatchQueue.main.async { self.onState?(up, problem) }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EHOSTUNREACH || code == .ENETUNREACH {
            return "No route to broker. Check Local Network access in System Settings > Privacy & Security."
        }
        return error.localizedDescription
    }
}
