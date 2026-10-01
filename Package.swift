// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SiriMouse",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CMultitouch"),
        .executableTarget(
            name: "SiriMouse",
            dependencies: ["CMultitouch"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
