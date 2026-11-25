// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockPane",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DockPane",
            path: "Sources/DockPane",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
