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
		// Dense 14B: the reliable pick for 16-24 GB Macs. ~8 GB resident (4-bit)
		// leaves headroom for the OS + FCP + the prefill spike, so it never swaps
		// on a 24 GB machine - unlike the MoE options below, whose ~17-19 GB
		// baseline sits right against the ceiling and thrashes during prefill.
		// Loads via the standard dense text path (no VLM factory). Tool-capable.
		LocalAIModel(
			id: "qwen3-14b",
			displayName: "Qwen3 14B",
			blurb: AILoc("Balanced, low memory"),
			sizeDescription: "~8 GB",
			minRAMGB: 16,
			repoID: "mlx-community/Qwen3-14B-4bit"
		),
		// MoE: 26B of knowledge, only 4B active per token, so it reasons like a
		// big model at ~4B speed. The dense 12B/31B would be ideal sizes but ship
		// as model_type "gemma4_unified", which mlx-swift-lm 3.31.3 can't load;
		// this A4B variant is "gemma4" and loads via the VLM factory (it drags in
		// vision weights). ~19 GB resident + the prefill spike overflows a 24 GB
		// Mac into swap, so it wants 32 GB - not a 24 GB recommendation.
		LocalAIModel(
			id: "gemma-4-26b-a4b",
			displayName: "Gemma 4 26B (A4B)",
			blurb: AILoc("Fast and capable"),
			sizeDescription: "~19 GB",
			minRAMGB: 32,
			repoID: "mlx-community/gemma-4-26b-a4b-it-4bit",
			usesVLMFactory: true
		),
		// Qwen3 30B MoE: 30B of weights, only ~3B active per token, so it reasons
		// like a big model at a fraction of the compute. Heaviest option (~17 GB
		// resident, wants 32 GB) - offered for big-RAM Macs; on 24 GB it loads but
		// isn't the recommended pick. Dense-MoE text model, loads via the standard
		// LLM path (model_type "qwen3_moe"), not the VLM factory.
		LocalAIModel(
			id: "qwen3-30b-a3b",
			displayName: "Qwen3 30B (A3B)",
			blurb: AILoc("Smartest, heaviest"),
			sizeDescription: "~17 GB",
			minRAMGB: 32,
			repoID: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
		),
	]

	public static func model(id: String) -> LocalAIModel? {
		models.first { $0.id == id }
	}

	/// Prefix marking a model the user downloaded OUTSIDE Keyframeless (adopted
	/// from their own HuggingFace cache) rather than a catalog entry. The suffix
	/// is the HF repo id, so no registry is needed to resolve it.
	public static let customIDPrefix = "custom:"

	public static func customID(repoID: String) -> String {
		customIDPrefix + repoID
	}

	public static func customRepoID(id: String) -> String? {
		id.hasPrefix(customIDPrefix) ? String(id.dropFirst(customIDPrefix.count)) : nil
	}

	/// Resolve any selectable model id - a catalog entry, or a synthetic row for
	/// an adopted custom model. Customs carry no RAM floor (they never join the
	/// recommendation) and load through the default text-LLM factory, with the
	/// runner falling back to the VLM factory on failure.
	public static func resolve(id: String) -> LocalAIModel? {
		if let m = model(id: id) { return m }
		guard let repoID = customRepoID(id: id) else { return nil }
		return LocalAIModel(
			id: id,
			displayName: repoID.components(separatedBy: "/").last ?? repoID,
			blurb: AILoc("Your model"),
			sizeDescription: "",
			minRAMGB: 0,
			repoID: repoID)
	}

	/// The largest model whose RAM requirement the host meets. `minRAMGB` is the
	/// TOTAL system RAM for comfortable (swap-free) use = the model's resident
	/// footprint + headroom for the OS, FCP, and the prefill spike. So the dense
	/// 14B (~8 GB) wants 16 GB and is the 24 GB pick; the ~17-19 GB MoE options
	/// want 32 GB. The buffer-cache cap (see MLXLocalLLMRunner) bounds retained
	/// buffers but not the live prefill spike. Falls back to the lightest entry.
	public static var recommendedModelID: String {
		let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
		let affordable = models.filter { ramGB >= $0.minRAMGB }
		return affordable.max(by: { $0.minRAMGB < $1.minRAMGB })?.id ?? models.first!.id
	}
}
