// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PluginPreferences",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PluginPreferences", type: .static, targets: ["PluginPreferences"])],
    targets: [.target(name: "PluginPreferences", publicHeadersPath: "include",
        cSettings: [.unsafeFlags(["-fobjc-arc"])],
        linkerSettings: [.linkedFramework("Foundation")])]
)
