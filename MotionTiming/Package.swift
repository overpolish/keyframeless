// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotionTiming",
    products: [.library(name: "MotionTiming", type: .static, targets: ["MotionTiming"])],
    targets: [.target(name: "MotionTiming", publicHeadersPath: "include")]
)
