import Foundation

/// OpenVPN-over-TCP wire framing: every packet is prefixed with its length
/// as a big-endian uint16. Reassembles the received byte stream into
/// packets and produces framed packets for sending.
public struct TCPPacketFramer: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds stream bytes and returns every packet they complete. Partial
    /// packets are retained until their remaining bytes arrive.
    public mutating func feed(_ bytes: Data) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var packets: [Data] = []
        while buffer.count >= 2 {
            let length = (Int(buffer[0]) << 8) | Int(buffer[1])
            guard length > 0 else { throw OpenVPNProtocolError.truncatedPacket }
            guard buffer.count >= 2 + length else { break }
            packets.append(Data(buffer[2..<(2 + length)]))
            buffer.removeFirst(2 + length)
        }
        return packets
    }

    /// Wraps one packet into its length-prefixed wire form.
    public static func frame(_ packet: Data) -> Data {
        var out = UInt16(packet.count).bigEndianBytes
        out.append(packet)
        return out
    }

    /// True while a partial packet is being reassembled.
    public var hasPartialData: Bool { !buffer.isEmpty }
}
