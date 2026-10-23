// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TailscaleGPUTracker",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TailscaleGPUTracker", targets: ["TailscaleGPUTracker"])],
    targets: [
        .target(name: "TrackerCore"),
        .executableTarget(name: "TailscaleGPUTracker", dependencies: ["TrackerCore"]),
        .testTarget(name: "TrackerCoreTests", dependencies: ["TrackerCore"]),
        .testTarget(name: "MonitorTests", dependencies: ["TailscaleGPUTracker", "TrackerCore"])
    ]
)
