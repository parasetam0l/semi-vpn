import Foundation
import OpenVPNCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: ovpn-cli <profile.ovpn> [options]

  --timeout SECONDS          give up if not ready in time (default 60)
  --hold SECONDS             stay connected this long after ready, then disconnect
                             (default: exit as soon as the tunnel is ready)
  --auth-user-pass USER PASS credentials for auth-user-pass profiles
  --auth-file PATH           credentials file: username on line 1, password on line 2
  --askpass PASSPHRASE       passphrase of an encrypted private key
  --no-ekm                   force classic PRF key derivation
  --verbose                  log control-channel message contents
  --trace                    print every wire packet (hex prefix)
  --dump PATH                append full wire-packet hex dumps to PATH

exit status: 0 ready (or held successfully), 1 failed, 2 usage, 3 timeout
"""

struct Options {
    var profilePath: String?
    var timeout: TimeInterval = 60
    var hold: TimeInterval?
    var authUser: String?
    var authPass: String?
    var keyPassphrase: String?
    var dumpPath: String?
    var trace = false
    var verbose = false
    var noEKM = false

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        func values(_ count: Int = 1) -> [String] {
            guard index + count < arguments.count else {
                print(usage)
                exit(2)
            }
            let result = Array(arguments[(index + 1)...(index + count)])
            index += count + 1
            return result
        }
        func number() -> Double {
            guard let value = Double(values()[0]) else {
                print(usage)
                exit(2)
            }
            return value
        }

        while index < arguments.count {
            switch arguments[index] {
            case "--timeout":
                options.timeout = number()
            case "--hold":
                options.hold = number()
            case "--auth-user-pass":
                let credentials = values(2)
                options.authUser = credentials[0]
                options.authPass = credentials[1]
            case "--auth-file":
                let path = values()[0]
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    print("error: cannot read auth file \(path)")
                    exit(2)
                }
                let lines = text.components(separatedBy: .newlines)
                options.authUser = lines.first
                options.authPass = lines.count > 1 ? lines[1] : ""
            case "--askpass":
                options.keyPassphrase = values()[0]
            case "--dump":
                options.dumpPath = values()[0]
            case "--no-ekm":
                options.noEKM = true
                index += 1
            case "--verbose":
                options.verbose = true
                index += 1
            case "--trace":
                options.trace = true
                index += 1
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                let argument = arguments[index]
                if argument.hasPrefix("--") || options.profilePath != nil {
                    print("error: unexpected argument \(argument)\n\n\(usage)")
                    exit(2)
                }
                options.profilePath = argument
                index += 1
            }
        }
        return options
    }
}

let options = Options.parse(CommandLine.arguments)
guard let profilePath = options.profilePath else {
    print(usage)
    exit(2)
}

guard let profileText = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
    print("error: cannot read profile \(profilePath)")
    exit(1)
}

var profile: OVPNProfile
do {
    let baseDirectory = URL(fileURLWithPath: profilePath).deletingLastPathComponent()
    profile = try OVPNParser().parse(OVPNProfileInliner.inline(profileText, baseDirectory: baseDirectory))
} catch {
    print("error: profile parse failed: \(error)")
    exit(1)
}
profile.keyPassphrase = options.keyPassphrase
for issue in profile.issues {
    print("\(issue.severity == .error ? "error" : "warning"): \(issue.message)")
}
if let authUser = options.authUser {
    profile.authUserPass = OVPNProfile.AuthUserPass(username: authUser, password: options.authPass ?? "")
}

print("profile: \(profile.remotes.map { "\($0.host):\($0.port)" }.joined(separator: ", "))")
print("transport: \(profile.transport.rawValue), cipher: \(profile.cipher.rawValue), digest: \(profile.digest?.rawValue ?? "default")")
print("tls-auth: \(profile.tlsAuthPEM != nil ? "yes" : "no"), tls-crypt: \(profile.tlsCryptPEM != nil ? "yes" : "no"), tls-crypt-v2: \(profile.tlsCryptV2PEM != nil ? "yes" : "no"), cert-auth: \(profile.certPEM != nil ? "yes" : "no")")

final class CLIHandler: OpenVPNConnection.Delegate {
    func connection(_ connection: OpenVPNConnection, stateChanged state: OpenVPNConnection.State) {
        print("[state] \(state)")
    }

    func connection(_ connection: OpenVPNConnection, didReceiveIPPacket packet: Data) {
        print("[data] received \(packet.count) bytes")
    }

    func connection(_ connection: OpenVPNConnection, log message: String) {
        print("[log] \(message)")
    }
}

func hexString(_ data: Data, limit: Int) -> String {
    data.prefix(limit).map { String(format: "%02x", $0) }.joined()
}

/// Wire-packet observer; runs on the connection queue, so it only captures
/// its parameters.
func makePacketObserver(trace: Bool, dumpFile: FileHandle?) -> (Bool, Data) -> Void {
    { outgoing, packet in
        guard let first = packet.first else { return }
        let opcode = (first >> 3) & 0x1F
        let tag = outgoing ? "OUT" : "IN "
        if trace {
            print("[\(tag)] opcode=\(opcode) len=\(packet.count) hex=\(hexString(packet, limit: 24))")
        }
        if let dumpFile {
            _ = try? dumpFile.write(contentsOf: Data("[\(tag)] \(opcode) \(hexString(packet, limit: packet.count))\n".utf8))
        }
    }
}

let dumpFile: FileHandle? = options.dumpPath.flatMap { path in
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    return FileHandle(forWritingAtPath: path)
}
_ = try? dumpFile?.seekToEnd()

let handler = CLIHandler()
let connection = OpenVPNConnection(profile: profile)
connection.verboseLogging = options.verbose
connection.delegate = handler
connection.preferTLSKeyExport = !options.noEKM
if options.trace || dumpFile != nil {
    connection.packetObserver = makePacketObserver(trace: options.trace, dumpFile: dumpFile)
}

let start = Date()
var readyAt: Date?
connection.connect()

while true {
    switch connection.state {
    case .ready:
        if readyAt == nil {
            readyAt = Date()
            print("SUCCESS: tunnel established")
            if let pushed = connection.pushedOptions {
                print("pushed: ip=\(pushed.ifconfigLocal ?? "-") routes=\(pushed.routes.count) dns=\(pushed.dnsServers.joined(separator: " ")) search=\(pushed.searchDomains.joined(separator: " ")) redirect=\(pushed.redirectGateway) mtu=\(pushed.tunMTU.map(String.init) ?? "-")")
                if let ipv6 = pushed.ifconfigIPv6Local {
                    print("pushed ipv6: ip=\(ipv6)/\(pushed.ifconfigIPv6Netbits ?? 64) routes=\(pushed.routesIPv6.count) redirect=\(pushed.redirectGatewayIPv6)")
                }
            }
            guard options.hold != nil else {
                exit(0)
            }
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
    if let readyAt, let hold = options.hold, Date().timeIntervalSince(readyAt) >= hold {
        print("HOLD COMPLETE after \(Int(hold))s (state: \(connection.state))")
        connection.disconnect()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        exit(0)
    }
    if readyAt == nil, Date().timeIntervalSince(start) >= options.timeout {
        print("TIMEOUT: connection did not reach ready state (last: \(connection.state))")
        exit(3)
    }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
