import Testing
import Foundation
@testable import OpenVPNCore

private func pushed(_ options: String) throws -> PushedOptions {
    guard case .reply(let pushed) = try PushParser.parseReply(Data("PUSH_REPLY,\(options)".utf8) + Data([0])) else {
        Issue.record("expected reply")
        return PushedOptions()
    }
    return pushed
}

@Test("an ifconfig with a single argument is ignored instead of crashing")
func testIfconfigSingleArgument() throws {
    let options = try pushed("ifconfig 10.8.0.2,peer-id 3")
    #expect(options.ifconfigLocal == nil)
    #expect(options.peerID == 3)
}

@Test("parses OpenVPN 2.6+ dns options with priorities, ports and domains")
func testDNSOption() throws {
    let options = try pushed(
        "dhcp-option DNS 192.0.2.53,dns server 1 address 10.8.0.2 [2001:db8::53]:53," +
        "dns server 0 address 10.8.0.1:53,dns server 0 resolve-domains corp.example,dns search-domains corp.example lab.example," +
        "dns server 0 dnssec yes"
    )
    // dns options take precedence over dhcp-option DNS.
    #expect(options.dnsServers == ["10.8.0.1", "10.8.0.2"])
    #expect(options.dnsIPv6Servers == ["2001:db8::53"])
    #expect(options.dnsResolveDomains == ["corp.example"])
    #expect(options.searchDomains == ["corp.example", "lab.example"])
}

@Test("dhcp-option DNS and DOMAIN apply when no dns option is pushed")
func testDHCPOptionDNS() throws {
    let options = try pushed("dhcp-option DNS 10.8.0.1,dhcp-option DOMAIN corp.example,dhcp-option DOMAIN-SEARCH lab.example,dhcp-option DNS6 2001:db8::1")
    #expect(options.dnsServers == ["10.8.0.1"])
    #expect(options.dnsIPv6Servers == ["2001:db8::1"])
    #expect(options.searchDomains == ["corp.example", "lab.example"])
}

@Test("parses IPv4 routes, excluded routes and redirect-gateway flags")
func testRoutes() throws {
    let options = try pushed(
        "route 10.0.0.0 255.0.0.0,route 172.16.5.1,route 192.168.50.0 255.255.255.0 net_gateway," +
        "route 10.20.0.0 255.255.0.0 vpn_gateway 5,route intranet.example 255.255.255.0,route 10.30.0.0 255.0.255.0"
    )
    #expect(options.routes == [
        PushedRoute(network: "10.0.0.0", netmask: "255.0.0.0"),
        PushedRoute(network: "172.16.5.1", netmask: "255.255.255.255"),
        PushedRoute(network: "192.168.50.0", netmask: "255.255.255.0", excluded: true),
        PushedRoute(network: "10.20.0.0", netmask: "255.255.0.0", metric: 5),
    ])
    #expect(!options.redirectGateway)

    #expect(try pushed("redirect-gateway def1 bypass-dhcp").redirectGateway)
    let ipv6Only = try pushed("redirect-gateway ipv6 !ipv4")
    #expect(!ipv6Only.redirectGateway)
    #expect(ipv6Only.redirectGatewayIPv6)
}

@Test("net30 and subnet ifconfig forms resolve to the right mask and gateway")
func testTopologyInference() throws {
    let net30 = try pushed("ifconfig 10.8.0.6 10.8.0.5")
    #expect(!net30.ifconfigUsesSubnet)
    #expect(net30.ipv4SubnetMask == "255.255.255.255")
    #expect(net30.ipv4Gateway == "10.8.0.5")

    let explicitNet30 = try pushed("topology net30,ifconfig 10.8.0.6 10.8.0.5,route-gateway 10.8.0.5")
    #expect(explicitNet30.ipv4SubnetMask == "255.255.255.255")

    let subnet = try pushed("ifconfig 10.8.0.2 255.255.255.0,route-gateway 10.8.0.1")
    #expect(subnet.ifconfigUsesSubnet)
    #expect(subnet.ipv4SubnetMask == "255.255.255.0")
    #expect(subnet.ipv4Gateway == "10.8.0.1")
}

@Test("flags unsupported pushed ciphers")
func testUnsupportedCipher() throws {
    let options = try pushed("cipher AES-192-GCM")
    #expect(options.cipher == nil)
    #expect(options.unsupportedCipher == "AES-192-GCM")
    #expect(try pushed("cipher aes-128-gcm").cipher == .aes128GCM)
}

@Test("parses continuation, auth-token, tun-mtu, block-ipv6 and protocol-flags")
func testMiscOptions() throws {
    let user = Data("alice".utf8).base64EncodedString()
    let options = try pushed("push-continuation 2,auth-token SESS_ID_abc,auth-token-user \(user),tun-mtu 1400,block-ipv6,protocol-flags cc-exit tls-ekm aead-epoch,reneg-sec 3600")
    #expect(options.continuation == 2)
    #expect(options.authToken == "SESS_ID_abc")
    #expect(options.authTokenUser == "alice")
    #expect(options.tunMTU == 1400)
    #expect(options.blockIPv6)
    #expect(options.supportsControlChannelExit)
    #expect(options.useTLSKeyExport)
    #expect(options.aeadEpoch)
    #expect(options.renegSeconds == 3600)
}

@Test("continuation messages merge by concatenating their options")
func testContinuationMerge() throws {
    let first = PushParser.splitOptions("PUSH_REPLY,route 10.1.0.0 255.255.0.0,push-continuation 2")
    let second = PushParser.splitOptions("PUSH_REPLY,route 10.2.0.0 255.255.0.0,ifconfig 10.8.0.2 255.255.255.0,push-continuation 1")
    let merged = PushParser.parse(options: first + second)
    #expect(merged.routes.map(\.network) == ["10.1.0.0", "10.2.0.0"])
    #expect(merged.ifconfigLocal == "10.8.0.2")
    #expect(merged.continuation == 1)
}

@Test("classifies server control messages")
func testServerControlMessages() throws {
    #expect(ServerControlMessage.parse("AUTH_FAILED") == .authFailed(reason: "", temporary: false, backoffSeconds: nil))
    #expect(ServerControlMessage.parse("AUTH_FAILED,bad password") == .authFailed(reason: "bad password", temporary: false, backoffSeconds: nil))
    #expect(ServerControlMessage.parse("AUTH_FAILED,TEMP[backoff 30,advance no]:try later")
            == .authFailed(reason: "try later", temporary: true, backoffSeconds: 30))
    #expect(ServerControlMessage.parse("AUTH_FAILED,TEMP:busy") == .authFailed(reason: "busy", temporary: true, backoffSeconds: nil))
    #expect(ServerControlMessage.parse("AUTH_PENDING,timeout 300,openurl") == .authPending(timeoutSeconds: 300, keywords: ["timeout 300", "openurl"]))
    #expect(ServerControlMessage.parse("AUTH_PENDING") == .authPending(timeoutSeconds: nil, keywords: []))
    #expect(ServerControlMessage.parse("RESTART,[N]maintenance") == .restart(reason: "maintenance", advanceRemote: true))
    #expect(ServerControlMessage.parse("RESTART") == .restart(reason: "", advanceRemote: false))
    #expect(ServerControlMessage.parse("HALT,bye") == .halt(reason: "bye"))
    #expect(ServerControlMessage.parse("EXIT") == .exit)
    #expect(ServerControlMessage.parse("INFO,hello") == .info("INFO,hello"))
}
