// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OctopusSync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OctopusSync", targets: ["OctopusSync"])
    ],
    targets: [
        .executableTarget(
            name: "OctopusSync",
            path: "Sources/OctopusSync",
            resources: [
                .copy("../../assets/MenuBarIcon.png"),
                .copy("../../assets/MenuBarIcon@2x.png"),
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-upcoming-feature", "GlobalActorIsolatedTypesUsability"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("Combine"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
