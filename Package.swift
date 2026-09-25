// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AccessibleLabel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AccessibleLabel",
            path: "Sources/AccessibleLabel",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
