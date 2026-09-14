// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "RenderSupport",
    platforms: [.macOS(.v13)],
    products: [.library(name: "RenderSupport", type: .static, targets: ["RenderSupport"])],
    targets: [.target(name: "RenderSupport", publicHeadersPath: "include",
        cSettings: [.unsafeFlags(["-fobjc-arc"])],
        linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreMedia"),
            .linkedFramework("Metal"), .linkedFramework("MetalPerformanceShaders")])]
)
