// swift-tools-version:6.2
import PackageDescription

// HerdrKit vendored into Loadout: the platform-independent core of the Herdr
// client — domain models, the newline-delimited JSON-RPC codec, the transport
// abstraction, the high-level client actor, and an in-memory Mock transport.
// Foundation-only, no third-party dependencies. Shared by the macOS and iOS
// Loadout apps in this monorepo.
let package = Package(
    name: "HerdrKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v17),
    ],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
    ],
    targets: [
        .target(name: "HerdrKit"),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit"]),
    ],
    swiftLanguageModes: [.v5]
)
