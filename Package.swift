// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Framed",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Framed", path: "Sources/Framed"),
        .testTarget(name: "FramedTests", dependencies: ["Framed"], path: "Tests/FramedTests"),
    ]
)
