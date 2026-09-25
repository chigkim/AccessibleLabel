// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AccessibleName",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AccessibleName",
            path: "Sources/AccessibleName",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
