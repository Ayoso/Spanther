// swift-tools-version:5.9
// GazeCore is plain Swift (no UIKit, no ARKit) so it builds and tests on any platform.
// The app target compiles these same sources directly; this package exists for `swift test`.
import PackageDescription

let package = Package(
    name: "GazeCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "GazeCore", targets: ["GazeCore"])],
    targets: [
        .target(name: "GazeCore"),
        .testTarget(name: "GazeCoreTests", dependencies: ["GazeCore"]),
        // `swift run GazeReplay <session.csv>`: replays an exported session through the current GazeCore code.
        // Not part of the app, which compiles only Sources/GazeCore.
        .executableTarget(name: "GazeReplay", dependencies: ["GazeCore"]),
    ]
)
