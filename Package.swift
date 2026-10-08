// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USBDriveMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "USBDriveMonitor", targets: ["USBDriveMonitor"])],
    targets: [.executableTarget(name: "USBDriveMonitor")]
)
