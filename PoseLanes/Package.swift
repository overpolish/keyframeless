// swift-tools-version: 5.9
import PackageDescription

// FxPlug ships as an SDK outside the toolchain, so the headers come from its
// fixed install path; linking stays with the plugin, which already carries
// the framework. unsafeFlags is allowed because the package is a local
// dependency of every plugin project.
let package = Package(
    name: "PoseLanes",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PoseLanes", type: .static, targets: ["PoseLanes"])],
    dependencies: [.package(path: "../PluginHost"), .package(path: "../InspectorControls"),
                   .package(path: "../MotionTiming")],
    targets: [.target(
        name: "PoseLanes",
        dependencies: ["PluginHost", "InspectorControls", "MotionTiming"],
        publicHeadersPath: "include",
        cSettings: [.unsafeFlags(["-fobjc-arc", "-F", "/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks"])],
        linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreMedia")]
    )]
)
