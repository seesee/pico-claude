import Foundation
import PicoClaudeCore
import ServiceManagement

/// Collects usage (this Mac's transcripts + reports from other hosts), merges
/// it, publishes it for the Pico, and exposes it to the menu bar UI.
@MainActor
final class AppModel: ObservableObject {
    static let usageTopic = "claude/usage"
    static let hostsPrefix = "claude/hosts/"
    static let onOffTopic = "unicorn/control/onoff"

    struct HostRow: Identifiable {
        var id: String { name }
        var name: String
        var todayTokens: Int
        var lastSeen: Int      // unix time of the host's last report
        var isLocal: Bool
    }

    @Published var payload: UsagePayload?
    @Published var hosts: [HostRow] = []
    @Published var connected = false
    @Published var problem: String?
    @Published var displayOn: Bool?          // nil until the broker tells us
    @Published var now = Date()
    @Published var brokerHost: String
    @Published var brokerPort: Int

    let localName = Host.current().localizedName ?? "This Mac"
    private let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pico-claude")
    private let scanner = TranscriptScanner(projectsDir:
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"))
    private let scanQueue = DispatchQueue(label: "pico-claude.scan", qos: .utility)
    private var local: HostReport?
    private var remotes: [String: HostReport] = [:]
    private var mqtt: MQTTClient?
    private var timer: Timer?
    private var lastPublished: UsagePayload?
    private var lastPublishTime = Date.distantPast

    init() {
        let defaults = UserDefaults.standard
        var host = defaults.string(forKey: "brokerHost") ?? ""
        var port = defaults.integer(forKey: "brokerPort")
        if host.isEmpty {
            // first run: adopt the broker the python publisher was configured with
            let config = (try? Data(contentsOf: stateDir.appendingPathComponent("config.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            host = config?["broker"] as? String ?? ""
            port = (config?["port"] as? NSNumber)?.intValue ?? 1883
        }
        brokerHost = host
        brokerPort = port == 0 ? 1883 : port
    }

    func start() {
        guard timer == nil else { return }
        let client = MQTTClient(clientID: "pico-claude-app",
                                topics: [Self.hostsPrefix + "+", Self.onOffTopic])
        client.onMessage = { [weak self] topic, data in
            MainActor.assumeIsolated { self?.received(topic, data) }
        }
        client.onState = { [weak self] up, problem in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connected = up
                self.problem = up ? nil : (problem ?? self.problem)
                if up { self.lastPublished = nil; self.refresh() }   // republish on reconnect
            }
        }
        mqtt = client
        applyBroker()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    func applyBroker() {
        UserDefaults.standard.set(brokerHost, forKey: "brokerHost")
        UserDefaults.standard.set(brokerPort, forKey: "brokerPort")
        guard !brokerHost.isEmpty else {
            problem = "Set the MQTT broker address."
            return
        }
        mqtt?.start(.init(host: brokerHost, port: brokerPort))
    }

    func setDisplay(on: Bool) {
        displayOn = on
        // retained, so the Pico comes back in the same state after a reboot
        mqtt?.publish(topic: Self.onOffTopic, payload: Data((on ? "ON" : "OFF").utf8), retain: true)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                problem = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - data flow

    private func scan() {
        let scanner = scanner
        let statusline = stateDir.appendingPathComponent("statusline")   // written by statusline-tee.sh
        let name = localName
        scanQueue.async {
            let hours = scanner.scan()
            let nowS = Int(Date().timeIntervalSince1970)
            let limits = readLimits(statuslineDir: statusline, now: nowS)
            let report = HostReport(host: name, ts: nowS,
                                    h5: limits.h5, d7: limits.d7, hours: hours)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.local = report
                    self.refresh()
                }
            }
        }
    }

    private func received(_ topic: String, _ data: Data) {
        if topic == Self.onOffTopic {
            switch String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "ON", "ONAIR", "OFFAIR": displayOn = true
            case "OFF": displayOn = false
            default: break
            }
        } else if topic.hasPrefix(Self.hostsPrefix) {
            let name = String(topic.dropFirst(Self.hostsPrefix.count))
            // an empty retained message is how a host is removed
            remotes[name] = data.isEmpty ? nil : HostReport(json: data)
            refresh()
        }
    }

    /// Re-merge and publish when the result changed, or as a once-a-minute
    /// heartbeat so the display knows the data is current.
    private func refresh() {
        now = Date()
        let reports = (local.map { [$0] } ?? []) + remotes.values.sorted { $0.host < $1.host }
        guard local != nil else { return }
        let merged = Aggregator.merge(reports, now: now, timeZone: .current)
        payload = merged
        hosts = reports.map { r in
            HostRow(name: r.host,
                    todayTokens: Aggregator.merge([r], now: now, timeZone: .current).today.tok,
                    lastSeen: r.ts, isLocal: r.host == localName)
        }
        var comparable = merged
        comparable.ts = lastPublished?.ts ?? 0
        if connected, comparable != lastPublished || now.timeIntervalSince(lastPublishTime) >= 60 {
            mqtt?.publish(topic: Self.usageTopic, payload: merged.json(), retain: true)
            lastPublished = merged
            lastPublishTime = now
        }
    }

    // MARK: - previews / snapshots

    static func sample() -> AppModel {
        let m = AppModel()
        let t = 1790868600
        m.now = Date(timeIntervalSince1970: TimeInterval(t))
        m.payload = UsagePayload(ts: t, tz: 3600,
                                 h5: LimitWindow(pct: 37.4, reset: t + 2 * 3600 + 13 * 60, ts: t - 240),
                                 d7: LimitWindow(pct: 78, reset: t + 3 * 86400 + 4 * 3600, ts: t - 240),
                                 today: .init(tok: 18_140_015, out: 104_118, msgs: 412),
                                 week: [5_200_000, 89_991, 0, 12_400_000, 17_777_385, 9_100_000, 18_140_015],
                                 model: "Fable 5.1")
        m.hosts = [HostRow(name: "MacBook Pro", todayTokens: 12_900_000, lastSeen: t - 5, isLocal: true),
                   HostRow(name: "buildbox", todayTokens: 5_100_000, lastSeen: t - 1500, isLocal: false),
                   HostRow(name: "pi5", todayTokens: 140_015, lastSeen: t - 30 * 3600, isLocal: false)]
        m.connected = true
        m.displayOn = true
        return m
    }
}
