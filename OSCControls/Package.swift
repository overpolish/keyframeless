// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OSCControls",
    products: [.library(name: "OSCControls", type: .static, targets: ["OSCControls"])],
    targets: [.target(name: "OSCControls", publicHeadersPath: "include",
        linkerSettings: [.linkedFramework("CoreGraphics")])]
)
