/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// One downloadable local model. The catalog is a plain array of these, so
/// adding a model later is a one-line append - no other code needs to change.
/// `minRAMGB` drives the hardware-based "Recommended" badge (mirrors Steno's
/// `recommendedModelId` heuristic): the largest model whose RAM floor the host
/// meets is the recommendation.
public struct LocalAIModel: Identifiable, Sendable {
	public let id: String
	public let displayName: String
	/// One-line blurb shown under the name (the "blurb under each" the design
	/// calls for). Keep it to a single sentence.
	public let blurb: String
	public let sizeDescription: String
	/// Rough resident RAM at this quantization, used for the recommendation
	/// heuristic only - not a hard gate.
	public let minRAMGB: Int
	/// HuggingFace repo id of the MLX (safetensors) model, e.g.
	/// `mlx-community/...-4bit`. MLX/Hub downloads + caches this on first load.
	public let repoID: String
	/// MoE / multimodal Gemma 4 checkpoints (e.g. 26B-A4B) must load through
	/// mlx's VLM factory - the LLM factory's dense Gemma4TextModel silently drops
	/// the expert/router weights. Dense text models (Qwen, Gemma 4 E4B) load via
	/// the default LLM path. Defaults to false.
	public var usesVLMFactory: Bool = false
}

public enum LocalModelCatalog {
	/// The shipping catalog. Order matters: rows render top-to-bottom in this
	/// order, and the recommendation prefers later (larger) entries when the
	/// hardware qualifies.
	public static let models: [LocalAIModel] = [
		LocalAIModel(
			id: "qwen-3.5-9b",
			displayName: "Qwen 3.5 9B",
			blurb: AILoc("Strong reasoning, needs 16 GB"),
			sizeDescription: "~5 GB",
			minRAMGB: 16,
			repoID: "mlx-community/Qwen3.5-9B-4bit"
		),
		// MoE: 26B of knowledge, only 4B active per token, so it reasons like a
		// big model at ~4B speed. The dense 12B/31B would be ideal sizes but ship
		// as model_type "gemma4_unified", which mlx-swift-lm 3.31.3 can't load;
		// this A4B variant is "gemma4" and loads via the same text path as E4B.
		LocalAIModel(
			id: "gemma-4-26b-a4b",
			displayName: "Gemma 4 26B (A4B)",
			blurb: AILoc("Best quality, needs 24 GB"),
			sizeDescription: "~16 GB",
			minRAMGB: 24,
			repoID: "mlx-community/gemma-4-26b-a4b-it-4bit",
			usesVLMFactory: true
		),
	]

	public static func model(id: String) -> LocalAIModel? {
		models.first { $0.id == id }
	}

	/// The largest model the host has the RAM for. Falls back to the first
	/// (lightest) entry on low-memory machines.
	public static var recommendedModelID: String {
		let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
		let affordable = models.filter { ramGB >= $0.minRAMGB }
		return affordable.max(by: { $0.minRAMGB < $1.minRAMGB })?.id ?? models.first!.id
	}
}
