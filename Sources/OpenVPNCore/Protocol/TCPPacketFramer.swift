import Foundation

/// OpenVPN-over-TCP wire framing: every packet is prefixed with its length
/// as a big-endian uint16. Reassembles the received byte stream into
/// packets and produces framed packets for sending.
public struct TCPPacketFramer: Sendable {
    private var buffer: [UInt8] = []
    /// Start of the unconsumed bytes; consumed bytes are compacted away in
    /// bulk instead of shifting the buffer once per packet.
    private var readIndex = 0

    public init() {}

    /// Feeds stream bytes and returns every packet they complete. Partial
    /// packets are retained until their remaining bytes arrive.
    public mutating func feed(_ bytes: Data) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var packets: [Data] = []
        while buffer.count - readIndex >= 2 {
            let length = (Int(buffer[readIndex]) << 8) | Int(buffer[readIndex + 1])
            guard length > 0 else { throw OpenVPNProtocolError.truncatedPacket }
            guard buffer.count - readIndex >= 2 + length else { break }
            packets.append(Data(buffer[(readIndex + 2)..<(readIndex + 2 + length)]))
            readIndex += 2 + length
        }
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 32 * 1024 {
            buffer.removeFirst(readIndex)
            readIndex = 0
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
    public var hasPartialData: Bool { buffer.count > readIndex }
}
