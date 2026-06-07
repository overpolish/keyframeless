// swift-tools-version: 5.10
import PackageDescription

let package = Package(
	name: "KeyframelessAI",
	defaultLocalization: "en",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "KeyframelessAI", targets: ["KeyframelessAI"])
	],
	dependencies: [
		// Apple's official MLX Swift LLM stack (in-process, Apple-Silicon).
		// 3.31.3 adds Gemma 4 (gemma4 / gemma4_text) and, crucially, drops the
		// swift-transformers dependency (it ships its own MLXHuggingFace), which
		// clears the long-standing version clash with WhisperKit in Steno.
		// Structured output no longer needs the third-party XGrammar package:
		// 3.x has native tool-calling (ToolSpec + ToolCallProcessor + per-model
		// parsers), which we use to coax valid JSON out of the local model.
		.package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
		// 3.x decouples the Hub/tokenizer impl from mlx (no more pinned
		// swift-transformers). The consumer supplies them; the MLXHuggingFace
		// macros adapt these into mlx's Downloader / TokenizerLoader. Versions
		// per the mlx-swift-lm 3.31.3 README.
		.package(
			url: "https://github.com/huggingface/swift-huggingface", .upToNextMajor(from: "0.9.0")),
		.package(
			url: "https://github.com/huggingface/swift-transformers", .upToNextMajor(from: "1.3.0")),
	],
	targets: [
		.target(
			name: "KeyframelessAI",
			dependencies: [
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
			path: "Sources/KeyframelessAI",
			resources: [.process("Resources")]
		)
	]
)
