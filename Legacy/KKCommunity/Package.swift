// swift-tools-version: 5.10
import PackageDescription

// Shared "community on GitHub" core: the payload-agnostic catalog fetch/download
// (and, later, publish) lifted from Steno's caption sharing so the Mirage plugin
// and the workflow extension share ONE implementation. Parameterised over the
// catalog folder ("Captions", "Shaders", ...) - the payload schema and the
// install action live in each consumer's adapter.
let package = Package(
  name: "KKCommunity",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "KKCommunity", targets: ["KKCommunity"])
  ],
  targets: [
    .target(name: "KKCommunity", path: "Sources/KKCommunity")
  ]
)
