import Foundation

/// Synthesizes RFC 4443 / RFC 8200 ICMPv6 error messages.
///
/// Used for IPv6 Leak Protection when connected to an IPv4-only VPN:
/// When an application (e.g. Chrome, Safari) attempts an IPv6 connection on a
/// dual-stack network, the tunnel captures the packet and immediately returns
/// an ICMPv6 Destination Unreachable message. This triggers RFC 8305 (Happy Eyeballs)
/// to immediately fall back to IPv4 without connection timeouts, ensuring all
/// traffic travels through the IPv4 VPN tunnel without leaking to the local ISP.
public enum ICMPv6Synthesizer {
    public static let defaultRouterIPv6 = "fd00:7365:6d69::1" // fd00:semi::1
    public static let defaultTunnelIPv6 = "fd00:7365:6d69::2" // fd00:semi::2

    /// Synthesizes an ICMPv6 Destination Unreachable packet in response to an invoking IPv6 packet.
    ///
    /// - Parameters:
    ///   - invokingPacket: The original raw IPv6 packet received on the tunnel interface.
    ///   - routerIPv6: The IPv6 address to use as the source of the ICMPv6 message.
    ///   - code: ICMPv6 Code. Defaults to 1 (Communication with destination administratively prohibited).
    /// - Returns: A complete raw IPv6 packet containing the ICMPv6 error response, or `nil` if suppressed.
    public static func makeDestinationUnreachable(
        invokingPacket: Data,
        routerIPv6: String = defaultRouterIPv6,
        code: UInt8 = 1
    ) -> Data? {
        // 1. Minimum IPv6 header length is 40 bytes
        guard invokingPacket.count >= 40 else { return nil }

        // 2. Validate IPv6 version (first nibble must be 6)
        guard (invokingPacket[0] >> 4) == 6 else { return nil }

        // 3. Extract addresses
        let srcIP = invokingPacket.subdata(in: 8..<24)
        let dstIP = invokingPacket.subdata(in: 24..<40)

        // RFC 4443 §2.4: Do not send ICMPv6 error messages if:
        // (e.3) The packet was sent to an IPv6 multicast address (ff00::/8)
        if dstIP[0] == 0xFF { return nil }

        // (e.5) Source address does not uniquely identify a single node (unspecified :: or multicast ff00::/8)
        if srcIP[0] == 0xFF { return nil }
        if srcIP.allSatisfy({ $0 == 0 }) { return nil }

        // (e.1) An ICMPv6 error message MUST NOT be sent as a result of receiving an ICMPv6 error message
        let nextHeader = invokingPacket[6]
        if nextHeader == 58 /* ICMPv6 */ {
            if invokingPacket.count > 40 {
                let icmpType = invokingPacket[40]
                // ICMPv6 error messages have type 0..<128 (informational messages have type >= 128)
                if icmpType < 128 { return nil }
            }
        }

        // 4. Resolve router IPv6 address bytes
        var routerAddr = in6_addr()
        if inet_pton(AF_INET6, routerIPv6, &routerAddr) != 1 {
            _ = inet_pton(AF_INET6, defaultRouterIPv6, &routerAddr)
        }
        let routerIPBytes = withUnsafeBytes(of: &routerAddr) { Data($0) }

        // 5. Truncate invoking packet so ICMPv6 packet does not exceed minimum IPv6 MTU (1280 bytes)
        // 1280 - 40 (IPv6 header) - 8 (ICMPv6 header) = 1232 bytes
        let maxPayload = min(invokingPacket.count, 1232)
        let invokingPayload = invokingPacket.prefix(maxPayload)

        // 6. Build ICMPv6 message body (Type 1, Code, Checksum placeholder, Unused 4 bytes, Payload)
        var icmpBody = Data()
        icmpBody.reserveCapacity(8 + invokingPayload.count)
        icmpBody.append(1) // Type = 1 (Destination Unreachable)
        icmpBody.append(code) // Code
        icmpBody.append(contentsOf: [0x00, 0x00]) // Checksum placeholder
        icmpBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Unused (32 bits zero)
        icmpBody.append(invokingPayload)

        // 7. Calculate ICMPv6 Checksum over IPv6 Pseudo-header + ICMPv6 message body
        // Pseudo-header:
        // - Source Address (16 bytes)
        // - Destination Address (16 bytes)
        // - Upper-Layer Packet Length (UInt32 big-endian, 4 bytes)
        // - Zero padding (3 bytes)
        // - Next Header = 58 (1 byte)
        var pseudoHeader = Data()
        pseudoHeader.reserveCapacity(40)
        pseudoHeader.append(routerIPBytes)
        pseudoHeader.append(srcIP)
        var lenBigEndian = UInt32(icmpBody.count).bigEndian
        withUnsafeBytes(of: &lenBigEndian) { pseudoHeader.append(contentsOf: $0) }
        pseudoHeader.append(contentsOf: [0x00, 0x00, 0x00, 58])

        var checksumData = Data()
        checksumData.reserveCapacity(pseudoHeader.count + icmpBody.count)
        checksumData.append(pseudoHeader)
        checksumData.append(icmpBody)

        let checksum = calculateChecksum(checksumData)
        icmpBody[2] = UInt8((checksum >> 8) & 0xFF)
        icmpBody[3] = UInt8(checksum & 0xFF)

        // 8. Build outer IPv6 Header (40 bytes)
        var packet = Data()
        packet.reserveCapacity(40 + icmpBody.count)
        // Version 6 (4 bits), Traffic Class = 0 (8 bits), Flow Label = 0 (20 bits) -> 0x60, 0x00, 0x00, 0x00
        packet.append(contentsOf: [0x60, 0x00, 0x00, 0x00])
        var payloadLenBigEndian = UInt16(icmpBody.count).bigEndian
        withUnsafeBytes(of: &payloadLenBigEndian) { packet.append(contentsOf: $0) }
        packet.append(58) // Next Header: ICMPv6
        packet.append(64) // Hop Limit: 64
        packet.append(routerIPBytes) // Source IPv6
        packet.append(srcIP) // Destination IPv6 (the original sender)
        packet.append(icmpBody)

        return packet
    }

    /// Computes standard 16-bit Internet checksum (RFC 1071).
    public static func calculateChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let count = data.count
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var index = 0
            while index + 1 < count {
                let word = (UInt32(base[index]) << 8) | UInt32(base[index + 1])
                sum &+= word
                index += 2
            }
            if index < count {
                let word = UInt32(base[index]) << 8
                sum &+= word
            }
        }
        while (sum >> 16) > 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }
}
