// swift-tools-version: 6.0
// Dewey.app: a SwiftUI shell over the dewey command-line tool. Build it with `make app` from the
// repo root (or open this file in Xcode). DeweyCore has everything that isn't UI, so it is testable.
import PackageDescription

let package = Package(
    name: "Dewey",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DeweyCore"),
        .executableTarget(name: "Dewey", dependencies: ["DeweyCore"]),
        .testTarget(name: "DeweyCoreTests", dependencies: ["DeweyCore"]),
    ]
)
