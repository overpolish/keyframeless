// swift-tools-version: 5.10
import PackageDescription

let package = Package(
	name: "KeyframelessAI",
	defaultLocalization: "en",
	platforms: [.macOS(.v14)],
	products: [
		// Thin client: providers, UI, keychain, plugin-agent, IPC wire types, the
		// LocalLLMRunner protocol + SharedHelperRunner, and model download. NO MLX -
		// this is what the sandboxed FxPlug plugins link, so the ~40 MB inference
		// engine never ends up in a plugin binary.
		.library(name: "KeyframelessAI", targets: ["KeyframelessAI"]),
		// Heavy local engine: MLX in-process runner + the helper server loop. Only
		// the standalone kk-ai-helper executable links this.
		.library(name: "KeyframelessAILocal", targets: ["KeyframelessAILocal"]),
		// The shared out-of-process helper, built once and shipped by the standalone
		// "Keyframeless AI" installer (signed Developer ID + app-group + hardened
		// runtime at packaging time). Never linked by a plugin.
		.executable(name: "kk-ai-helper", targets: ["kk-ai-helper"]),
	],
	dependencies: [
		// Apple's official MLX Swift LLM stack (in-process, Apple-Silicon). Heavy
		// target only. 3.31.3 adds Gemma 4 and drops the swift-transformers
		// dependency (ships its own MLXHuggingFace), clearing the version clash with
		// WhisperKit in Steno. 3.x has native tool-calling for JSON output.
		.package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
		// Hub client/cache for model download (thin) + tokenizer loader macros (heavy).
		.package(
			url: "https://github.com/huggingface/swift-huggingface", .upToNextMajor(from: "0.9.0")),
		.package(
			url: "https://github.com/huggingface/swift-transformers", .upToNextMajor(from: "1.3.0")),
	],
	targets: [
		.target(
			// No external deps: model DOWNLOAD moved to the helper (KeyframelessAILocal),
			// so plugins linking this don't pull in swift-huggingface / swift-nio.
			name: "KeyframelessAI",
			path: "Sources/KeyframelessAI",
			resources: [.process("Resources")]
		),
		.target(
			name: "KeyframelessAILocal",
			dependencies: [
				"KeyframelessAI",
				.product(name: "MLXLLM", package: "mlx-swift-lm"),
				// VLM factory for MoE/multimodal Gemma 4 (26B-A4B) - its MoE blocks
				// are only implemented on the VLM side, not the dense LLM Gemma4.
				.product(name: "MLXVLM", package: "mlx-swift-lm"),
				.product(name: "MLXLMCommon", package: "mlx-swift-lm"),
				// 3.x downloader/tokenizer macros (#hubDownloader / #huggingFaceTokenizerLoader).
				.product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
				.product(name: "HuggingFace", package: "swift-huggingface"),
				.product(name: "Tokenizers", package: "swift-transformers"),
			],
			path: "Sources/KeyframelessAILocal"
		),
		.executableTarget(
			name: "kk-ai-helper",
			dependencies: ["KeyframelessAILocal"],
			path: "Sources/kk-ai-helper"
		),
	]
)
