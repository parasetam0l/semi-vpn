// swift-tools-version: 6.0
import PackageDescription

let opensslRoot = "/opt/homebrew/opt/openssl@3"

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
