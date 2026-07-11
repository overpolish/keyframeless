/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation
import HuggingFace
import KeyframelessAI
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
import os

/// Timing log for local inference. Lands in the unified log; view in Console.app
/// by filtering subsystem `co.overpolish.keyframeless` category `ai.local`
/// (the plugin runs as an XPC process, so also filter by that process name).
private let localLog = Logger(subsystem: "co.overpolish.keyframeless", category: "ai.local")

/// In-process local inference via Apple's MLX. Loads the model once (cached
/// across calls) and runs entirely inside the calling process - no helper, no
/// XPC, no launch infrastructure. MLX keeps weights in Metal/IOGPU buffers,
/// which is why this survives the FxPlug XPC memory budget.
///
/// Structured passes use MLX's native tool-calling: the schema is registered as
/// a single forced "tool", and we read back the parsed `ToolCall` arguments.
/// Tool-call-trained models (Gemma, Qwen3) emit these reliably; a parse miss is
/// retried once before erroring. This replaced XGrammar (mlx-swift-structured),
/// which capped mlx-swift-lm at <3.0.0 and blocked the Gemma 4 / 3.x bump.
public actor MLXLocalLLMRunner: LocalLLMRunner {
	enum RunnerError: LocalizedError {
		case unknownModel(String)
		case badJSON(String)
		var errorDescription: String? {
			switch self {
			case .unknownModel(let id): return "Unknown local model: \(id)"
			case .badJSON(let raw): return "Local model didn't return JSON. Raw: \(raw)"
			}
		}
	}

	private var container: ModelContainer?
	private var loadedRepoID: String?

	/// A local "think" pass (reason freely, then grammar-format) roughly DOUBLES
	/// each structured step - and verbose models (Qwen3 especially) ramble to the
	/// token cap, so the reasoning pass alone can run ~50s on a 9B. Off by default:
	/// one-shot structured output is usually fine and keeps the pipeline snappy.
	/// Flip to true to trade speed for quality on hard prompts.
	nonisolated(unsafe) static var thinkingEnabled = false

	public init() {
		Self.capCacheOnce()
	}

	/// MLX's buffer cache defaults to the FULL memory limit (~1.5x the device
	/// working set), so during inference it accumulates many GB of freed-but-
	/// retained buffers - a 4-bit 9B whose WEIGHTS are ~5 GB balloons to ~15 GB
	/// resident (measured), which on a 24 GB unified-memory Mac (shared with FCP)
	/// forces swap and was the cause of the swapping/thrash. Cap it to keep the
	/// footprint near the live model size. Measured: 512 MB vs 2 GB made NO
	/// difference to prefill/decode speed here, so we take the smaller footprint.
	/// Only bounds RETAINED freed buffers, not live allocations; `memoryLimit`
	/// untouched.
	nonisolated(unsafe) private static var cacheCapped = false
	private static func capCacheOnce() {
		guard !cacheCapped else { return }
		cacheCapped = true
		let before = MLX.Memory.cacheLimit
		MLX.Memory.cacheLimit = 512 * 1024 * 1024
		localLog.notice(
			"GPU cacheLimit \(before, privacy: .public) -> 512MB (bound footprint, avoid swap)")
	}

	public func complete(
		modelID: String, system: String, user: String, jsonSchemaJSON: String?,
		enableThinking: Bool
	) async throws -> String {
		guard let model = LocalModelCatalog.model(id: modelID) else {
			throw RunnerError.unknownModel(modelID)
		}
		localLog.notice(
			"complete start model=\(modelID, privacy: .public) schema=\(jsonSchemaJSON != nil, privacy: .public) thinking=\(enableThinking, privacy: .public)"
		)
		let loadStart = Date()
		let container = try await loadContainer(model: model)
		localLog.notice("load done in \(Self.ms(loadStart), privacy: .public)ms")

		// Leave the pipeline's per-pass label ("Planning timing", "Choosing a
		// look", "Resolving Color 1", …) showing while we generate - it changes as
		// passes complete, so the user sees real progress, same as cloud. (We used
		// to overwrite it with "Thinking" here, but that raced the pipeline's label
		// and just made it flash a step then snap back to "Thinking".)

		// Qwen3 non-thinking recommended sampling (temp 0.7 / top_p 0.8 / top_k 20).
		// NOT greedy/low-temp - Qwen warns that degrades quality + repeats. The
		// grammar guarantees JSON shape, so sampling only affects content quality.
		let params = GenerateParameters(maxTokens: 4096, temperature: 0.7, topP: 0.8, topK: 20)

		// Plain text (no schema): ChatSession is fine.
		guard let schemaString = jsonSchemaJSON else {
			let session = ChatSession(
				container,
				instructions: system,
				generateParameters: params,
				additionalContext: ["enable_thinking": false]
			)
			let genStart = Date()
			// Wrap MLX generation so a Metal/MLX error (e.g. a prompt that exceeds
			// the model's context) throws a Swift error instead of MLX's default
			// fatalError - which would crash the whole helper process and leave the
			// next request hitting a dead socket ("helper exited unexpectedly").
			let text = LocalLLM.stripThink(
				try await withError { try await session.respond(to: user) })
			localLog.notice("text gen done in \(Self.ms(genStart), privacy: .public)ms")
			return text
		}

		// Two-pass for reasoning-heavy passes: grammar-constrained JSON leaves no
		// room for <think> tokens, so let the model reason FREELY first (pass 1),
		// then fold that analysis into the grammar-constrained JSON (pass 2). Single
		// pass for simple structured calls (classify/styles) to avoid the 2x cost.
		// The thinking budget is capped hard: routing/timing reasoning fits in a few
		// hundred tokens, and an uncapped budget lets Qwen3 ramble for thousands of
		// tokens - the difference between a snappy answer and a minute-long stall.
		var formatSystem = system
		if enableThinking && Self.thinkingEnabled {
			// Qwen3 thinking-mode recommended sampling. Budget capped HARD at 384:
			// routing/timing reasoning fits in a couple hundred tokens, and Qwen3
			// otherwise rambles straight to the cap (1024 tok ≈ 50s on a 9B).
			let thinkParams = GenerateParameters(
				maxTokens: 384, temperature: 0.6, topP: 0.95, topK: 20)
			let thinker = ChatSession(
				container,
				instructions: system,
				generateParameters: thinkParams,
				additionalContext: ["enable_thinking": true]
			)
			let thinkStart = Date()
			let analysis = LocalLLM.stripThink(
				try await withError { try await thinker.respond(to: user) })
			localLog.notice("think pass done in \(Self.ms(thinkStart), privacy: .public)ms")
			formatSystem =
				system + "\n\nThe request was analysed as follows:\n\(analysis)"
				+ "\n\nNow return the result by calling the function."
		}

		// Structured pass: prompt for raw JSON with the schema in the system
		// prompt, then extract the {...} from the reply. We deliberately do NOT
		// use mlx's tool-calling: its inline ToolCallProcessor buffers anything
		// starting with `{` expecting a {name,arguments} envelope and SWALLOWS a
		// bare result object (never emitted as a chunk OR parsed as a tool call).
		// Retry once on a miss; the raw output is logged/surfaced for diagnosis.
		let fmtStart = Date()
		var result = try await Self.generateStructured(
			container: container, system: formatSystem, user: user,
			schemaString: schemaString, params: params)
		if result.json == nil {
			localLog.notice(
				"format pass: no JSON. rawLen=\(result.raw.count, privacy: .public) raw=\(result.raw.prefix(500), privacy: .public)"
			)
			result = try await Self.generateStructured(
				container: container, system: formatSystem, user: user,
				schemaString: schemaString, params: params)
		}
		localLog.notice("format pass done in \(Self.ms(fmtStart), privacy: .public)ms")
		guard let json = result.json else {
			throw RunnerError.badJSON(String(result.raw.prefix(400)))
		}
		return json
	}

	/// Token-by-token plain-text generation for the answer path. Same setup as the
	/// no-schema branch of `complete`, but yields each chunk as it's produced so
	/// the popover can render the reply live (decode is ~30 tok/s, so a multi-
	/// second answer appears as it's written instead of all at once at the end).
	public func completeStreaming(
		modelID: String, system: String, user: String
	) async -> AsyncThrowingStream<String, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					guard let model = LocalModelCatalog.model(id: modelID) else {
						throw RunnerError.unknownModel(modelID)
					}
					let container = try await loadContainer(model: model)
					// Keep the pipeline's label (e.g. "Answering") showing; the
					// answer also streams into the card, so progress is visible.
					let params = GenerateParameters(
						maxTokens: 4096, temperature: 0.7, topP: 0.8, topK: 20)
					let session = ChatSession(
						container, instructions: system, generateParameters: params,
						additionalContext: ["enable_thinking": false])
					try await withError {
						for try await chunk in session.streamResponse(
							to: user, images: [], videos: [])
						{
							continuation.yield(chunk)
						}
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private struct StructuredResult {
		let json: String?
		let raw: String
	}

	/// Structured generation by prompting for a raw JSON object (schema embedded
	/// in the system prompt) and extracting the outermost {...} from the reply.
	/// Returns the raw text too so callers can diagnose a parse miss.
	private static func generateStructured(
		container: ModelContainer, system: String, user: String,
		schemaString: String, params: GenerateParameters
	) async throws -> StructuredResult {
		let jsonSystem =
			system + "\n\n"
			+ "Respond with ONLY a single JSON object conforming to this JSON Schema. "
			+ "No prose, no explanation, no markdown code fences - just the raw JSON. "
			+ "Every number must be a plain decimal literal (e.g. 0.092), never a "
			+ "fraction or arithmetic expression like 1/10.867. No trailing commas.\n\n"
			+ "JSON Schema:\n\(schemaString)"
		let session = ChatSession(
			container,
			instructions: jsonSystem,
			generateParameters: params,
			additionalContext: ["enable_thinking": false]
		)
		let text = LocalLLM.stripThink(
			try await withError { try await session.respond(to: user) })
		return StructuredResult(json: Self.extractJSONObject(from: text), raw: text)
	}

	/// Best-effort: return the substring from the first `{` to the last `}` if
	/// it parses as a JSON object, else nil. Small local models sometimes emit
	/// not-quite-JSON (an arithmetic expression like `"time": 1 / 10.867` instead
	/// of `0.092`, or a trailing comma), which a strict parser rejects - so if the
	/// raw candidate fails, we repair those quirks and retry once.
	private static func extractJSONObject(from s: String) -> String? {
		guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"),
			open < close
		else { return nil }
		let candidate = String(s[open...close])
		if Self.parsesAsObject(candidate) { return candidate }
		let repaired = Self.repairLooseJSON(candidate)
		if repaired != candidate, Self.parsesAsObject(repaired) { return repaired }
		return nil
	}

	private static func parsesAsObject(_ s: String) -> Bool {
		guard let data = s.data(using: .utf8) else { return false }
		return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
	}

	/// Fix the two not-JSON things small models emit most: arithmetic in a value
	/// position (`: 1 / 10.867`) and trailing commas before `}`/`]`.
	private static func repairLooseJSON(_ s: String) -> String {
		var out = Self.evalValueArithmetic(s)
		if let tc = try? NSRegularExpression(pattern: #",(\s*[}\]])"#) {
			out = tc.stringByReplacingMatches(
				in: out, range: NSRange(out.startIndex..., in: out),
				withTemplate: "$1")
		}
		// Strip INVALID backslash escapes: small models emitting a long string
		// (e.g. an SVG document) routinely write `\<`, `\#`, `\ ` etc., which JSON
		// rejects (only \" \\ \/ \b \f \n \r \t \uXXXX are legal). Drop the stray
		// backslash; valid escapes (incl. `\\`) are preserved by the lookahead.
		if let esc = try? NSRegularExpression(pattern: #"\\(?!["\\/bfnrtu])"#) {
			out = esc.stringByReplacingMatches(
				in: out, range: NSRange(out.startIndex..., in: out),
				withTemplate: "")
		}
		return out
	}

	/// Evaluate `number op number` only where it sits in a JSON value position
	/// (right after `:`, `[`, or `,`), so keys and string contents are untouched.
	/// Repeats leftmost-first to fold chains; capped to avoid any runaway.
	private static func evalValueArithmetic(_ s: String) -> String {
		guard
			let regex = try? NSRegularExpression(
				pattern:
					#"([:\[,]\s*)(-?\d+(?:\.\d+)?)\s*([-+*/])\s*(-?\d+(?:\.\d+)?)"#)
		else { return s }
		var out = s
		for _ in 0..<200 {
			let full = NSRange(out.startIndex..., in: out)
			guard let m = regex.firstMatch(in: out, range: full),
				let rAll = Range(m.range, in: out),
				let rPre = Range(m.range(at: 1), in: out),
				let rA = Range(m.range(at: 2), in: out),
				let rOp = Range(m.range(at: 3), in: out),
				let rB = Range(m.range(at: 4), in: out),
				let a = Double(out[rA]), let b = Double(out[rB])
			else { break }
			let v: Double
			switch out[rOp.lowerBound] {
			case "+": v = a + b
			case "-": v = a - b
			case "*": v = a * b
			default: v = b != 0 ? a / b : 0
			}
			out.replaceSubrange(rAll, with: String(out[rPre]) + Self.numLiteral(v))
		}
		return out
	}

	private static func numLiteral(_ v: Double) -> String {
		if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
		var s = String(format: "%.6f", v)
		while s.hasSuffix("0") { s.removeLast() }
		if s.hasSuffix(".") { s.removeLast() }
		return s
	}

	private func loadContainer(model: LocalAIModel) async throws -> ModelContainer {
		if let container, loadedRepoID == model.repoID { return container }
		await LocalRunnerStatus.report(AILoc("Loading model"))
		// MoE/multimodal Gemma 4 must go through the VLM factory (its MoE blocks
		// live there); dense text models use the default LLM loader.
		let loaded: ModelContainer
		let hub = Self.hubClient()
		if model.usesVLMFactory {
			loaded = try await VLMModelFactory.shared.loadContainer(
				from: #hubDownloader(hub), using: #huggingFaceTokenizerLoader(),
				configuration: ModelConfiguration(id: model.repoID))
		} else {
			loaded = try await loadModelContainer(
				from: #hubDownloader(hub), using: #huggingFaceTokenizerLoader(), id: model.repoID)
		}
		container = loaded
		loadedRepoID = model.repoID
		return loaded
	}

	/// HubClient that loads from the SHARED app-group model cache so the host app
	/// and the spawned helper find the model the clients downloaded - never
	/// re-downloading. The host resolves the group container directly (it's
	/// entitled); the spawned helper (which may not be) reads the `HF_HUB_CACHE`
	/// the parent passed. Falls back to the default cache (e.g. in-process plugins).
	private static func hubClient() -> HubClient {
		if let dir = LocalAIHelperSocket.sharedModelCacheDir() {
			return HubClient(cache: HubCache(cacheDirectory: dir))
		}
		if let env = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !env.isEmpty {
			return HubClient(cache: HubCache(cacheDirectory: URL(fileURLWithPath: env)))
		}
		return HubClient()
	}

	/// Elapsed milliseconds since `start`, rounded, for timing logs.
	private static func ms(_ start: Date) -> Int {
		Int((Date().timeIntervalSince(start) * 1000).rounded())
	}
}
