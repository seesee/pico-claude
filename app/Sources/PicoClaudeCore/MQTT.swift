import Foundation

/// MQTT 3.1.1 packet framing - just what a QoS 0 publisher/subscriber needs.
public enum MQTT {
    public struct Packet: Equatable {
        public var type: UInt8
        public var flags: UInt8
        public var body: [UInt8]
    }

    static func string(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    static func length(_ n: Int) -> [UInt8] {
        var n = n
        var out: [UInt8] = []
        repeat {
            let b = UInt8(n % 128)
            n /= 128
            out.append(n > 0 ? b | 0x80 : b)
        } while n > 0
        return out
    }

    static func packet(_ head: UInt8, _ body: [UInt8]) -> Data {
        Data([head] + length(body.count) + body)
    }

    public static func connect(clientID: String, user: String? = nil, password: String? = nil,
                               keepAlive: UInt16 = 60) -> Data {
        var flags: UInt8 = 0x02   // clean session
        var payload = string(clientID)
        if let user, !user.isEmpty {
            flags |= 0x80
            payload += string(user)
            if let password, !password.isEmpty {
                flags |= 0x40
                payload += string(password)
            }
        }
        return packet(0x10, string("MQTT") + [4, flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)] + payload)
    }

    public static func subscribe(topics: [String], packetID: UInt16 = 1) -> Data {
        packet(0x82, [UInt8(packetID >> 8), UInt8(packetID & 0xFF)] + topics.flatMap { string($0) + [0] })
    }

    public static func publish(topic: String, payload: Data, retain: Bool) -> Data {
        packet(retain ? 0x31 : 0x30, string(topic) + Array(payload))
    }

    public static let pingRequest = Data([0xC0, 0x00])

    /// Topic and payload of a PUBLISH packet, or nil for any other packet.
    public static func message(from p: Packet) -> (topic: String, payload: Data)? {
        guard p.type == 3, p.body.count >= 2 else { return nil }
        let topicLen = Int(p.body[0]) << 8 | Int(p.body[1])
        let start = 2 + topicLen + (p.flags & 0x06 != 0 ? 2 : 0)   // skip packet id if QoS > 0
        guard p.body.count >= start, let topic = String(bytes: p.body[2..<2 + topicLen], encoding: .utf8)
        else { return nil }
        return (topic, Data(p.body[start...]))
    }

    /// Reassembles packets from a byte stream that arrives in arbitrary chunks.
    public struct Decoder {
        private var buffer: [UInt8] = []

        public init() {}

        public mutating func feed(_ data: Data) -> [Packet] {
            buffer += data
            var packets: [Packet] = []
            while true {
                guard buffer.count >= 2 else { break }
                var length = 0, shift = 0, index = 1
                var complete = false
                while index < buffer.count && index <= 4 {
                    let b = buffer[index]
                    length |= Int(b & 0x7F) << shift
                    shift += 7
                    index += 1
                    if b & 0x80 == 0 { complete = true; break }
                }
                guard complete, buffer.count >= index + length else { break }
                packets.append(Packet(type: buffer[0] >> 4, flags: buffer[0] & 0x0F,
                                      body: Array(buffer[index..<index + length])))
                buffer.removeFirst(index + length)
            }
            return packets
        }
    }
}
