import Foundation
import OpenVPNCore

final class CLIHandler: OpenVPNConnection.Delegate {
    func connection(_ connection: OpenVPNConnection, stateChanged state: OpenVPNConnection.State) {
        print("[state] \(state)")
        fflush(stdout)
    }

    func connection(_ connection: OpenVPNConnection, didReceiveIPPacket packet: Data) {
        print("[data] received \(packet.count) bytes")
        fflush(stdout)
    }

    func connection(_ connection: OpenVPNConnection, log message: String) {
        print("[log] \(message)")
        fflush(stdout)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: ovpn-cli <profile.ovpn> [--timeout SECONDS]")
    exit(2)
}

let profilePath = arguments[1]
var timeout: TimeInterval = 60

var index = 2
while index < arguments.count {
    if arguments[index] == "--timeout", index + 1 < arguments.count {
        timeout = Double(arguments[index + 1]) ?? timeout
        index += 2
    } else if arguments[index] == "--auth-user-pass", index + 2 < arguments.count {
        authUser = arguments[index + 1]
        authPass = arguments[index + 2]
        index += 3
    } else {
        index += 1
    }
}

guard let profileText = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
    print("error: cannot read profile \(profilePath)")
    exit(1)
}

var authUser: String?
var authPass: String?
let profile: OVPNProfile
do {
    profile = try OVPNParser().parse(profileText)
} catch {
    print("error: profile parse failed: \(error)")
    exit(1)
}

print("profile: \(profile.remotes.map { "\($0.host):\($0.port)" }.joined(separator: ", "))")
print("transport: \(profile.transport.rawValue), cipher: \(profile.cipher.rawValue), digest: \(profile.digest?.rawValue ?? "none")")
print("tls-auth: \(profile.tlsAuthPEM != nil ? "yes" : "no"), tls-crypt-v2: \(profile.tlsCryptV2PEM != nil ? "yes" : "no"), cert-auth: \(profile.certPEM != nil ? "yes" : "no")")
fflush(stdout)

let dumpFile: FileHandle? = FileHandle(forWritingAtPath: "/tmp/ovpn_wire_dump.log")
var verboseControlMessages = false
let handler = CLIHandler()
let connection: OpenVPNConnection
if let authUser, let authPass {
    var modified = profile
    modified.authUserPass = OVPNProfile.AuthUserPass(username: authUser, password: authPass)
    modified.requiresAuthUserPass = true
    connection = OpenVPNConnection(profile: modified)
} else {
    connection = OpenVPNConnection(profile: profile)
}
connection.verboseLogging = CommandLine.arguments.contains("--verbose")
connection.delegate = handler
if CommandLine.arguments.contains("--no-ekm") {
    connection.preferTLSKeyExport = false
}
connection.packetObserver = { outgoing, packet in
    let opcode = (packet[0] >> 3) & 0x1F
    let tag = outgoing ? "OUT" : "IN "
    print("[\(tag)] opcode=\(opcode) len=\(packet.count) hex=\(hexPrefix(packet, 24))")
    fflush(stdout)
    if let dump = dumpFile {
        let line = "[\(tag)] \(opcode) \(hexPrefix(packet, packet.count))\n"
        try? dump.seekToEnd()
        try? dump.write(contentsOf: Data(line.utf8))
    }
}

func hexPrefix(_ data: Data, _ length: Int) -> String {
    let bytes = [UInt8](data.prefix(length))
    var out = ""
    out.reserveCapacity(length * 2)
    for byte in bytes {
        out.append(String(byte >> 4, radix: 16))
        out.append(String(byte & 0xF, radix: 16))
    }
    return out
}

let start = Date()
var connected = false
connection.connect()

while Date().timeIntervalSince(start) < timeout {
    switch connection.state {
    case .ready:
        if !connected {
            connected = true
            print("SUCCESS: tunnel established")
        }
    case .failed(let reason):
        print("FAILED: \(reason)")
        exit(1)
    case .disconnected:
        print("DISCONNECTED")
        exit(1)
    default:
        break
    }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}

if connected {
    print("SESSION ENDED after timeout")
    exit(0)
}
print("TIMEOUT: connection did not reach ready state (last: \(connection.state))")
exit(1)
