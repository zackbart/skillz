// swift-tools-version: 5.9
import PackageDescription

// HerdrKit is the platform-independent core of the Herdr iOS client: domain
// models, the newline-delimited JSON-RPC codec, the transport abstraction, the
// high-level client actor, and an in-memory Mock transport. It has no Apple-SDK
// or third-party dependencies, so it builds and unit-tests with `swift test` on
// macOS or Linux. The SwiftUI app target (see project.yml) depends on this
// package plus Citadel for SSH.
let package = Package(
    name: "HerdrKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
    ],
    targets: [
        .target(name: "HerdrKit"),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit"]),
    ]
)
