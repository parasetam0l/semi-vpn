// swift-tools-version: 6.0
import PackageDescription
import Foundation

/// OpenSSL 3: $OPENSSL_ROOT, else Homebrew's openssl@3 (Apple Silicon or
/// Intel location).
let opensslRoot: String = {
    if let root = ProcessInfo.processInfo.environment["OPENSSL_ROOT"], !root.isEmpty {
        return root
    }
    let candidates = ["/opt/homebrew/opt/openssl@3", "/usr/local/opt/openssl@3"]
    return candidates.first { FileManager.default.fileExists(atPath: $0 + "/lib/libssl.3.dylib") } ?? candidates[0]
}()

let package = Package(
    name: "SwiftOpenVPNCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenVPNCore", targets: ["OpenVPNCore"]),
        .executable(name: "ovpn-cli", targets: ["OpenVPNCLI"]),
    ],
    targets: [
        .target(
            name: "COpenVPNTLS",
            cSettings: [
                .unsafeFlags(["-I", opensslRoot + "/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", opensslRoot + "/lib"]),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto"),
            ]
        ),
        .target(
            name: "OpenVPNCore",
            dependencies: ["COpenVPNTLS"]
        ),
        .executableTarget(
            name: "OpenVPNCLI",
            dependencies: ["OpenVPNCore"]
        ),
        .testTarget(
            name: "OpenVPNCoreTests",
            dependencies: ["OpenVPNCore"]
        ),
    ]
)
