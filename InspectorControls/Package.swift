// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InspectorControls",
    platforms: [.macOS(.v13)],
    products: [.library(name: "InspectorControls", type: .static, targets: ["InspectorControls"])],
    targets: [.target(
        name: "InspectorControls",
        publicHeadersPath: "include",
        cSettings: [.unsafeFlags(["-fobjc-arc"])],
        linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreGraphics")]
    )]
)
