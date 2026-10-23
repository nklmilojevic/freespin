// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Freespin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HIDPP", targets: ["HIDPP"]),
        .library(name: "ScrollEngine", targets: ["ScrollEngine"]),
        .library(name: "EventSynth", targets: ["EventSynth"]),
        .library(name: "Flow", targets: ["Flow"]),
        .library(name: "FreespinCore", targets: ["FreespinCore"]),
        .executable(name: "freespinctl", targets: ["freespinctl"]),
        .executable(name: "FreespinApp", targets: ["FreespinApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "HIDPP", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "ScrollEngine"),
        .target(name: "EventSynth", dependencies: ["ScrollEngine"], linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "Flow", linkerSettings: [.linkedFramework("Network"), .linkedFramework("AppKit")]),
        .target(name: "FreespinCore", dependencies: ["HIDPP", "ScrollEngine", "EventSynth", "Flow"]),
        .executableTarget(name: "freespinctl", dependencies: ["FreespinCore"]),
        .executableTarget(name: "FreespinApp", dependencies: ["FreespinCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "HIDPPTests", dependencies: ["HIDPP"]),
        .testTarget(name: "ScrollEngineTests", dependencies: ["ScrollEngine"]),
        .testTarget(name: "FreespinCoreTests", dependencies: ["FreespinCore"]),
        .testTarget(name: "EventSynthTests", dependencies: ["EventSynth"]),
        .testTarget(name: "FlowTests", dependencies: ["Flow", "FreespinCore", "HIDPP"]),
    ],
    swiftLanguageModes: [.v5]
)
