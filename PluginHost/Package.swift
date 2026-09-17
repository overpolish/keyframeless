// swift-tools-version: 5.9
import PackageDescription

// FxPlug ships as an SDK outside the toolchain, so the headers come from its
// fixed install path; linking stays with the plugin, which already carries
// the framework. unsafeFlags is allowed because the package is a local
// dependency of every plugin project.
let package = Package(
    name: "PluginHost",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PluginHost", type: .static, targets: ["PluginHost"])],
    dependencies: [.package(path: "../InspectorControls"), .package(path: "../OSCViewer"),
                   .package(path: "../RenderSupport")],
    targets: [.target(
        name: "PluginHost",
        dependencies: ["InspectorControls", "OSCViewer", "RenderSupport"],
        publicHeadersPath: "include",
        cSettings: [.unsafeFlags(["-fobjc-arc", "-F", "/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks"])],
        linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
                         .linkedFramework("CoreMedia"), .linkedFramework("Metal")]
    )]
)
