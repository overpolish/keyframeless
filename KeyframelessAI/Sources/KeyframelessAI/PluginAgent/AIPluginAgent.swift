/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

@objc(KKAIPluginResultKind)
public enum AIPluginResultKind: Int {
	case answer = 0
	case mutation = 1
}

/// Returned by `AIPluginAgent.run(...)`. Either `.answer(String)` (Q&A reply)
/// or `.mutation(String)` where the mutation is JSON of shape
/// `{ "operations": [{ "lane": "...", "keyposes": [{ "time": ..., "values": [...], "outgoing": {...} }] }] }`.
/// The host plugin merges this into its current timeline JSON and writes
/// it back through the existing param-mutation path.
@objc(KKAIPluginResult)
public final class AIPluginResult: NSObject {
	@objc public let kind: AIPluginResultKind
	@objc public let answer: String?
	@objc public let mutationJSON: String?

	init(answer: String) {
		self.kind = .answer
		self.answer = answer
		self.mutationJSON = nil
		super.init()
	}

	init(mutationJSON: String) {
		self.kind = .mutation
		self.answer = nil
		self.mutationJSON = mutationJSON
		super.init()
	}
}

/// Multi-pass orchestrator for natural-language → KKTiming mutations.
///
/// Pass 0a (classify)    - router: answer / mutation / vague + complexity flag
///                         + template fast-path resolution.
/// Pass 0b (answer)      - only fires on Q&A prompts; loads docs and replies.
/// Template (Swift)      - skips remaining passes when classifier resolved a
///                         known shape (e.g. modulate + lane).
/// Pass 1  (timing)      - keypose times, interval kinds, phase plan.
/// Pass 2  (values)      - numeric values per new keypose, per lane.
/// Pass 3  (styles)      - curve + modulation per interval, per lane.
/// Compile (Swift)       - assemble JSON, preserve values/styles deterministically.
///
/// Every LLM call uses provider-native structured outputs (Anthropic forced
/// `tool_choice`, OpenAI `response_format: json_schema`) so the model can't
/// emit malformed shapes - it either conforms or fails.
@objc(KKAIPluginAgent)
public final class AIPluginAgent: NSObject {
	@MainActor
	@objc public static func run(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		currentTimelineJSON: String,
		clipDurationSeconds: Double,
		currentInspectorMode: String,
		completion: @escaping (AIPluginResult?, Error?) -> Void
	) {
		Task { @MainActor in
			do {
				let result = try await runAsync(
					prompt: prompt,
					productContext: productContext,
					laneSchemaText: laneSchemaText,
					currentTimelineJSON: currentTimelineJSON,
					clipDurationSeconds: clipDurationSeconds,
					currentInspectorMode: currentInspectorMode
				)
				completion(result, nil)
			} catch {
				completion(nil, error)
			}
		}
	}

	@MainActor
	static func runAsync(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		currentTimelineJSON: String,
		clipDurationSeconds: Double,
		currentInspectorMode: String
	) async throws -> AIPluginResult {
		AIDraftState.shared.routingStatus = AILoc("Reading prompt…")
		// Pass 0a: classify. No docs in this prompt - classifier is just a
		// router. If the answer path wins, Pass 0b loads docs and writes the
		// reply. This keeps the mutation path (the hot path) cheap. We
		// expose the lane labels so the classifier can resolve template
		// fast-paths in natural language ("wobble the radius" → modulate
		// + Radius) without us maintaining a synonym list in Swift.
		let labels = laneLabels(
			fromTimelineJSON: currentTimelineJSON,
			fallbackSchemaText: laneSchemaText)
		let classification = try await classify(
			prompt: prompt, productContext: productContext, laneLabels: labels)
		if classification.kind == "answer" {
			let docs = await renderDocs(for: prompt)
			let reply = try await answerQuestion(
				prompt: prompt, productContext: productContext, docs: docs)
			return AIPluginResult(answer: reply)
		}
		if classification.kind == "vague" {
			// Surface the classifier's clarification as an answer result so
			// the popover renders it like any reply. Avoids burning thinking
			// budget on prompts that can't succeed.
			let clarification =
				classification.clarification?.trimmingCharacters(
					in: .whitespacesAndNewlines) ?? ""
			let reply =
				clarification.isEmpty
				? "Could you be a bit more specific about what you'd like to change?"
				: clarification
			return AIPluginResult(answer: reply)
		}

		// Template fast-path: classifier resolved a known shape, Swift builds
		// the mutation directly and skips Pass 1/2/3.
		if classification.template == "modulate",
			!classification.templateLane.isEmpty,
			let templated = buildModulateTemplate(
				lane: classification.templateLane,
				modulation: classification.templateModulation,
				currentTimelineJSON: currentTimelineJSON)
		{
			return AIPluginResult(mutationJSON: templated)
		}

		AIDraftState.shared.routingStatus = AILoc("Planning timing…")
		// Pass 1: timing. Thinking only when the classifier flagged the prompt
		// as "complex" - simple template-matchable prompts don't need 4k
		// reasoning tokens.
		let timing = try await planTiming(
			prompt: prompt,
			productContext: productContext,
			laneSchemaText: laneSchemaText,
			currentTimelineJSON: currentTimelineJSON,
			clipDurationSeconds: clipDurationSeconds,
			currentInspectorMode: currentInspectorMode,
			enableThinking: classification.complexity == "complex"
		)
		// Phases are the authoritative orchestration when present (multi-lane
		// / temporal prompts). Derive per-lane operations from them and
		// discard whatever the LLM dropped in `operations`. For single-lane
		// prompts Pass 1 leaves phases empty and we use `operations` as-is.
		let effectiveOperations: [TimingOperation]
		if !timing.phases.isEmpty {
			effectiveOperations = deriveOperationsFromPhases(timing.phases)
		} else {
			effectiveOperations = timing.operations
		}
		guard !effectiveOperations.isEmpty else {
			return AIPluginResult(answer: AILoc("Couldn't figure out which lanes to change."))
		}

		// Pass 2 + Pass 3 per operation, in parallel (independent given Pass 1).
		let currentLanes = extractLanes(fromTimelineJSON: currentTimelineJSON)
		let currentIntervals =
			extractIntervals(fromTimelineJSON: currentTimelineJSON)
		var compiledOps: [[String: Any]] = []
		let totalOps = effectiveOperations.count
		let complex = classification.complexity == "complex"
		for (opIdx, op) in effectiveOperations.enumerated() {
			let suffix = totalOps > 1 ? " (\(opIdx + 1)/\(totalOps))" : ""
			let laneLabel = "\(op.lane)\(suffix)"
			AIDraftState.shared.routingStatus = AILoc("Resolving \(laneLabel)…")
			let oldKeyposes = currentLanes[op.lane] ?? []
			let oldIntervals = currentIntervals[op.lane] ?? []
			async let valuesAsync = resolveValues(
				prompt: prompt,
				productContext: productContext,
				laneSchemaText: laneSchemaText,
				operation: op,
				clipDurationSeconds: clipDurationSeconds,
				existingKeyposes: oldKeyposes,
				enableThinking: complex
			)
			// Pass 3 always runs (cheap Haiku, no thinking) so we don't have
			// to guess at colloquial style intent in Swift. Existing-interval
			// preservation is still handled deterministically in compile.
			async let stylesAsync = planCurves(
				prompt: prompt,
				productContext: productContext,
				operation: op,
				existingIntervals: oldIntervals
			)
			let values = try await valuesAsync
			let styles = try await stylesAsync
			compiledOps.append(
				buildOperationJSON(
					timingOp: op,
					values: values,
					styles: styles,
					existingKeyposes: oldKeyposes,
					existingIntervals: oldIntervals))
		}

		let mutation: [String: Any] = ["operations": compiledOps]
		let data = try JSONSerialization.data(withJSONObject: mutation)
		let json = String(data: data, encoding: .utf8) ?? "{\"operations\":[]}"
		return AIPluginResult(mutationJSON: json)
	}
}
