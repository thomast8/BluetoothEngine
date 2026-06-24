// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "BluetoothEngine",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "BluetoothEngine", targets: ["BluetoothEngine"]),
        .executable(name: "sensor", targets: ["SensorCLI"]),
        .executable(name: "sensor-debug", targets: ["SensorDebugApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "BluetoothEngine"
        ),
        .executableTarget(
            name: "SensorCLI",
            dependencies: [
                "BluetoothEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                // Embed the Info.plist (NSBluetoothAlwaysUsageDescription) so a code-signed CLI run has
                // a Bluetooth-usage rationale. Note: a bare unsigned binary still TCC-crashes — sign it.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SensorCLI/Resources/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "SensorDebugApp",
            dependencies: ["BluetoothEngine"],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SensorDebugApp/Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "BluetoothEngineTests",
            dependencies: ["BluetoothEngine"]
        ),
    ]
)
