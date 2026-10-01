import XCTest
@testable import PicoClaudeCore

private let london = TimeZone(identifier: "Europe/London")!

/// 2026-10-01 16:30 BST
private let now = Date(timeIntervalSince1970: 1790868600)
private let nowHour = 1790868600 / 3600

final class ModelTests: XCTestCase {
    func testPrettyModel() {
        XCTAssertEqual(prettyModel("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(prettyModel("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(prettyModel(""), "")
    }

    func testHostReportDecoding() {
        let json = #"{"v":2,"host":"box","ts":100,"h5":{"pct":7.5,"reset":900,"ts":90},"d7":null,"hours":[[5,"claude-fable-5-1",112,105,2],["bad"]]}"#
        let r = HostReport(json: Data(json.utf8))
        XCTAssertEqual(r, HostReport(host: "box", ts: 100, h5: LimitWindow(pct: 7.5, reset: 900, ts: 90), d7: nil,
                                     hours: [HourBucket(hour: 5, model: "claude-fable-5-1", tok: 112, out: 105, msgs: 2)]))
        XCTAssertNil(HostReport(json: Data("nope".utf8)))
        XCTAssertNil(HostReport(json: Data()))
    }

    func testPayloadJSONMatchesDisplayContract() throws {
        let p = UsagePayload(ts: 5, tz: 3600, h5: LimitWindow(pct: 4, reset: 9, ts: 1), d7: nil,
                             today: .init(tok: 1, out: 2, msgs: 3), week: [0, 1], model: "Fable 5.1")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: p.json()) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual((obj["h5"] as? [String: Any])?["pct"] as? Double, 4)
        XCTAssertEqual((obj["today"] as? [String: Any])?["tok"] as? Int, 1)
        XCTAssertEqual(obj["week"] as? [Int], [0, 1])
        XCTAssertNil(obj["d7"])
    }
}

final class AggregatorTests: XCTestCase {
    func testSameWindowHighestPercentageWins() {
        // an idle session re-saves its stale percentage, so capture time says nothing
        let stale = LimitWindow(pct: 16, reset: 5000, ts: 200)
        let high = LimitWindow(pct: 22, reset: 5000, ts: 100)
        XCTAssertEqual(Aggregator.best([stale, nil, high], now: 300), high)
        XCTAssertNil(Aggregator.best([nil, nil], now: 300))
    }

    func testLaterWindowBeatsHigherPercentage() {
        let last = LimitWindow(pct: 90, reset: 5000, ts: 100)
        let fresh = LimitWindow(pct: 2, reset: 23000, ts: 90)
        XCTAssertEqual(Aggregator.best([last, fresh], now: 300), fresh)
    }

    func testResetTimesAFewSecondsApartAreOneWindow() {
        let a = LimitWindow(pct: 30, reset: 5000, ts: 100)
        let b = LimitWindow(pct: 12, reset: 5002, ts: 100)
        XCTAssertEqual(Aggregator.best([a, b], now: 300), a)
    }

    func testLiveWindowBeatsExpiredNewerCapture() {
        let expired = LimitWindow(pct: 80, reset: 250, ts: 290)
        let live = LimitWindow(pct: 7, reset: 9000, ts: 280)
        XCTAssertEqual(Aggregator.best([expired, live], now: 300), live)
    }

    func testExpiredWindowReadsZero() {
        let w = LimitWindow(pct: 80, reset: 250, ts: 100)
        XCTAssertEqual(Aggregator.best([w], now: 300), LimitWindow(pct: 0, reset: 0, ts: 100))
    }

    func testMergeSumsHostsAndCutsDaysInLocalTime() {
        let mac = HostReport(host: "mac", ts: 0, h5: LimitWindow(pct: 10, reset: 1790880000, ts: 1790860000),
                             d7: nil, hours: [
            HourBucket(hour: nowHour, model: "claude-fable-5-1", tok: 100, out: 10, msgs: 1),
            HourBucket(hour: nowHour - 48, model: "claude-fable-5-1", tok: 7, out: 1, msgs: 1),
        ])
        let box = HostReport(host: "box", ts: 0, h5: LimitWindow(pct: 25, reset: 1790880000, ts: 1790868000),
                             d7: LimitWindow(pct: 3, reset: 1791300000, ts: 1790868000), hours: [
            HourBucket(hour: nowHour - 1, model: "claude-opus-5-5", tok: 50, out: 40, msgs: 2),
            // 23:30 BST the previous evening is 22:30 UTC: yesterday locally
            HourBucket(hour: nowHour - 17, model: "claude-opus-5-5", tok: 5, out: 5, msgs: 1),
            HourBucket(hour: nowHour - 24 * 30, model: "claude-opus-5-5", tok: 999, out: 9, msgs: 1),
        ])
        let p = Aggregator.merge([mac, box], now: now, timeZone: london)
        XCTAssertEqual(p.today, .init(tok: 150, out: 50, msgs: 3))
        XCTAssertEqual(p.week, [0, 0, 0, 0, 7, 5, 150])
        XCTAssertEqual(p.model, "Opus 5.5")
        XCTAssertEqual(p.h5?.pct, 25)            // box heard from Anthropic more recently
        XCTAssertEqual(p.d7?.pct, 3)
        XCTAssertEqual(p.tz, 3600)
    }

    func testMergeOfNothing() {
        let p = Aggregator.merge([], now: now, timeZone: london)
        XCTAssertEqual(p.week, [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(p.model, "")
        XCTAssertNil(p.h5)
    }
}

final class ScannerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj/sub"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func line(_ offset: Double, id: String, out: Int, model: String = "claude-fable-5-1") -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = f.string(from: now.addingTimeInterval(offset))
        return #"{"type":"assistant","requestId":"r","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1,"output_tokens":\#(out),"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}"# + "\n"
    }

    func testIncrementalDedupAndPartialLines() throws {
        let file = dir.appendingPathComponent("proj/a.jsonl")
        let partial = line(-8, id: "m2", out: 1)
        try (line(-10, id: "m1", out: 5) + line(-9, id: "m1", out: 50) + partial.dropLast(20))
            .write(to: file, atomically: true, encoding: .utf8)
        let scanner = TranscriptScanner(projectsDir: dir)
        XCTAssertEqual(scanner.scan(now: now),
                       [HourBucket(hour: nowHour, model: "claude-fable-5-1", tok: 56, out: 50, msgs: 1)])
        try (line(-10, id: "m1", out: 5) + line(-9, id: "m1", out: 50) + partial)
            .write(to: file, atomically: true, encoding: .utf8)
        let again = scanner.scan(now: now)
        XCTAssertEqual(again, [HourBucket(hour: nowHour, model: "claude-fable-5-1", tok: 63, out: 51, msgs: 2)])
        XCTAssertEqual(scanner.scan(now: now), again)
    }

    func testNestedFilesSkipsSyntheticAndOldEntries() throws {
        let text = line(-5, id: "n1", out: 4) + line(-5, id: "s", out: 9, model: "<synthetic>")
            + line(-20 * 86400, id: "old", out: 9) + "{\"usage\": broken\n" + "{\"type\":\"user\",\"usage\":1}\n"
        try text.write(to: dir.appendingPathComponent("proj/sub/b.jsonl"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("proj/notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptScanner(projectsDir: dir).scan(now: now),
                       [HourBucket(hour: nowHour, model: "claude-fable-5-1", tok: 10, out: 4, msgs: 1)])
    }

    func testReadLimits() throws {
        let captures = dir.appendingPathComponent("statusline")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        // the idle session wrote last, with the lower percentage it last heard
        try #"{"rate_limits":{"five_hour":{"used_percentage":23.46,"resets_at":2000}}}"#
            .write(to: captures.appendingPathComponent("busy.json"), atomically: true, encoding: .utf8)
        try #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":2000}}}"#
            .write(to: captures.appendingPathComponent("idle.json"), atomically: true, encoding: .utf8)
        let limits = readLimits(statuslineDir: captures, now: 1000)
        XCTAssertEqual(limits.h5?.pct, 23.5)
        XCTAssertEqual(limits.h5?.reset, 2000)
        XCTAssertNil(limits.d7)
        XCTAssertNil(readLimits(statuslineDir: dir.appendingPathComponent("missing"), now: 1000).h5)
    }

    func testOldCapturesArePruned() throws {
        let captures = dir.appendingPathComponent("statusline")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let file = captures.appendingPathComponent("a.json")
        try #"{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":500}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let nowS = 100 * 86400
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(nowS - 9 * 86400))], ofItemAtPath: file.path)
        XCTAssertNil(readLimits(statuslineDir: captures, now: nowS).h5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

final class MQTTTests: XCTestCase {
    func testEncodersMatchPythonAgent() {
        XCTAssertEqual(MQTT.publish(topic: "a/b", payload: Data("hi".utf8), retain: true),
                       Data([0x31, 0x07, 0x00, 0x03] + Array("a/bhi".utf8)))
        XCTAssertEqual(MQTT.connect(clientID: "c"),
                       Data([0x10, 0x0d, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3c, 0x00, 0x01, 0x63]))
        XCTAssertEqual(MQTT.subscribe(topics: ["a/b", "c"]),
                       Data([0x82, 0x0c, 0x00, 0x01, 0x00, 0x03] + Array("a/b".utf8) + [0x00, 0x00, 0x01, 0x63, 0x00]))
        XCTAssertEqual(Array(MQTT.publish(topic: "t", payload: Data(repeating: 0x78, count: 200), retain: false).prefix(3)),
                       [0x30, 0xcb, 0x01])
    }

    func testDecoderHandlesSplitAndCoalescedPackets() {
        let big = Data(repeating: 0x78, count: 300)
        let stream = Data([0x20, 0x02, 0x00, 0x00]) + MQTT.publish(topic: "c", payload: Data("hi".utf8), retain: true)
            + MQTT.publish(topic: "a/b", payload: big, retain: false) + Data([0xD0, 0x00])
        var decoder = MQTT.Decoder()
        var packets: [MQTT.Packet] = []
        for chunk in stride(from: 0, to: stream.count, by: 7) {      // awkward chunk size
            packets += decoder.feed(stream.subdata(in: chunk..<min(chunk + 7, stream.count)))
        }
        XCTAssertEqual(packets.map(\.type), [2, 3, 3, 13])
        XCTAssertEqual(MQTT.message(from: packets[1])?.topic, "c")
        XCTAssertEqual(MQTT.message(from: packets[1])?.payload, Data("hi".utf8))
        XCTAssertEqual(MQTT.message(from: packets[2])?.payload, big)
        XCTAssertNil(MQTT.message(from: packets[0]))
    }

    func testEmptyRetainedPayload() {
        var decoder = MQTT.Decoder()
        let packets = decoder.feed(MQTT.publish(topic: "claude/hosts/x", payload: Data(), retain: true))
        XCTAssertEqual(MQTT.message(from: packets[0])?.payload, Data())
    }
}
