// swift-tools-version: 5.10
import PackageDescription

let package = Package(
	name: "KeyframelessAI",
	defaultLocalization: "en",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "KeyframelessAI", targets: ["KeyframelessAI"])
	],
	targets: [
		.target(
			name: "KeyframelessAI",
			path: "Sources/KeyframelessAI",
			resources: [.process("Resources")]
		)
	]
)
