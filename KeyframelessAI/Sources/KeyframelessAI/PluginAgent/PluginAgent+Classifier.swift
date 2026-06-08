/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	struct Classification {
		let kind: String
		/// "simple" for template-matchable mutations (modulate, from-to,
		/// in-over-N, on-the-left, set X). "complex" when arithmetic or
		/// multi-lane reasoning is needed. Drives whether Pass 1 enables
		/// extended thinking. Always "simple" for answer/vague prompts.
		let complexity: String
		/// Populated when kind == "vague": a one-sentence ask for the
		/// missing detail (which lane / what value / what time range).
		let clarification: String?
		/// "none" when no template applies. "modulate" when the user asked
		/// for any kind of constant shake/wobble/breathing on one lane -
		/// classifier maps natural-language synonyms (wobble, jiggle,
		/// tremor, shimmer, pulse, etc.) to this. More templates can be
		/// added later (e.g. "set_constant").
		let template: String
		/// Lane label the template targets, matched against the lanes the
		/// classifier was shown. Empty when template == "none".
		let templateLane: String
		/// For template == "modulate": which modulation kind (wiggle,
		/// oscillate, handheld). Default "wiggle" when the colloquial term
		/// doesn't specify.
		let templateModulation: String
	}

	/// A plainly-phrased question (ends with "?", opens with a question word).
	/// Routes straight to the answer path, skipping the classify LLM call - one
	/// fewer ~100 tok/s prefill pass, and it avoids small models misrouting a
	/// question to "mutation". Commands ("spin once", "move left") don't match, so
	/// they still go through the classifier.
	static func looksLikeQuestion(_ prompt: String) -> Bool {
		let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.hasSuffix("?") else { return false }
		let first = String(t.lowercased().prefix(while: { $0.isLetter }))
		let qWords: Set<String> = [
			"what", "whats", "how", "hows", "why", "when", "where", "who", "whos",
			"which", "whose", "whom", "can", "could", "does", "do", "did", "is",
			"are", "am", "was", "were", "will", "would", "should", "explain", "tell",
		]
		return qWords.contains(first)
	}

	@MainActor
	static func classify(
		prompt: String, productContext: String, laneLabels: [String]
	) async throws -> Classification {
		// Obvious questions bypass the (locally expensive) LLM router.
		if looksLikeQuestion(prompt) {
			return Classification(
				kind: "answer", complexity: "simple", clarification: nil,
				template: "none", templateLane: "", templateModulation: "")
		}
		let laneList =
			laneLabels.isEmpty
			? "(no lanes available)"
			: laneLabels.map { "\"\($0)\"" }.joined(separator: ", ")
		let system = """
			Route a user message for \(productContext)'s AI animation assistant. \
			Output a kind, complexity, optional clarification, and optional template \
			fast-path.

			Available lanes: \(laneList)

			kind:
			  "answer"   - user is asking a QUESTION about the tool.
			  "mutation" - user describes a SPECIFIC change to the animation. Has \
			               enough detail to act on (some combination of lane, value, \
			               time range, or a known modulation/style intent).
			  "vague"    - user wants a mutation but it's not actionable: missing \
			               which lane, what value/direction, or what time range. \
			               Examples: "make it cool", "animate something", "improve it".

			complexity (only relevant for mutations; pick "simple" otherwise):
			  "simple"  - matches a known pattern on ONE lane: "from A to B", \
			              "in over N", "out over N", "on the left/right/middle", \
			              any modulation request, "set X to Y", "appear", or \
			              trivial combinations.
			  "complex" - ALWAYS pick this when ANY of the following is true:
			              * Two or more lanes are referenced ("radius and crop", \
			                "scale while position", "rotate then fade").
			              * A temporal connective appears: "then", "and then", \
			                "after", "first ... then", "while", "whilst", "during", \
			                "as ... happens", "once ... reaches".
			              * Arithmetic or conditional logic is needed.
			              * The prompt asks for something outside the simple \
			                templates above.

			clarification (only when kind = "vague"; empty otherwise):
			  ONE short sentence asking for the missing detail. Examples:
			    "Which property would you like to animate (e.g. radius, position)?"
			    "What value should it animate to?"
			    "Over what part of the clip - the start, end, or middle?"
			  Never apologize, never offer to help, never list capabilities.

			template (fast-path; "none" by default):
			  "modulate" - user wants any kind of CONSTANT shake, wobble, jiggle, \
			               vibration, tremor, breathing, pulsing, oscillation, or \
			               shimmer applied to ONE specific lane for the whole clip. \
			               Synonyms include: wiggle, wobble, jiggle, jitter, shake, \
			               tremor, tremble, shimmer, pulse, pulsate, breathe, \
			               oscillate, vibrate, flutter, judder, twitch, hum, buzz, \
			               handheld, camera-shake.
			               Only use when ONE lane from the available list is clearly \
			               named or strongly implied. If the lane is ambiguous, do \
			               NOT pick this template - set kind = "vague" instead.
			  "none"     - everything else (multipass will handle).

			template_lane (only when template = "modulate"): EXACT lane label from \
			the Available lanes list above. Match the user's wording to the closest \
			label. Empty string when template = "none".

			template_modulation (only when template = "modulate"):
			  "wiggle"    - default for generic shake/jiggle/wobble/tremor/jitter/ \
			                shimmer/pulse/breathe/vibrate
			  "oscillate" - explicit oscillation, swinging back and forth, sine-like
			  "handheld"  - camera-shake, handheld feel, organic drift

			When uncertain between "answer" and "vague", prefer "vague".

			The effect is always implicit (single live instance); never ask the \
			user to select anything.
			"""
		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": [
				"kind", "complexity", "clarification",
				"template", "template_lane", "template_modulation",
			],
			"properties": [
				"kind": ["type": "string", "enum": ["answer", "mutation", "vague"]],
				"complexity": ["type": "string", "enum": ["simple", "complex"]],
				"clarification": ["type": "string"],
				"template": ["type": "string", "enum": ["none", "modulate"]],
				"template_lane": ["type": "string"],
				"template_modulation": [
					"type": "string",
					"enum": ["", "wiggle", "oscillate", "handheld"],
				],
			],
		]
		let raw = try await AIStructuredCall.call(
			system: system,
			userMessage: prompt,
			schemaName: "classify_intent",
			schemaDescription:
				"Decide whether the user wants an answer or a mutation, and rate prompt complexity.",
			jsonSchema: schema,
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini",
			// Cloud models route correctly in a single grammar-constrained pass.
			// A small local model can't: it has to emit `kind` as its first token
			// with no room to reason, and flips clear mutations to "answer". Give
			// local the two-pass (reason freely, then format) treatment so routing
			// is reliable - it's the decision the whole pipeline hinges on.
			enableThinking: AIKeyState.shared.activeProvider == .local
		)
		let data = raw.data(using: .utf8) ?? Data()
		let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		return Classification(
			kind: obj["kind"] as? String ?? "answer",
			complexity: obj["complexity"] as? String ?? "simple",
			clarification: obj["clarification"] as? String,
			template: obj["template"] as? String ?? "none",
			templateLane: obj["template_lane"] as? String ?? "",
			templateModulation: obj["template_modulation"] as? String ?? ""
		)
	}

	/// Pass 0b: only fires when Pass 0a returned `answer`. Loads the docs and
	/// produces the user-facing reply. Splitting this out means mutation
	/// prompts (the hot path) never pay for docs tokens.
	@MainActor
	static func answerQuestion(
		prompt: String, productContext: String, docs: String
	) async throws -> String {
		let system = """
			You answer questions about \(productContext) for an in-app AI assistant. \
			Reply in 1-3 sentences, grounded in the reference docs. No labels, no \
			preambles, no apologies. Plain prose only - no markup, XML/HTML tags, \
			or <...> style symbols; the answer is shown as plain text. If the docs \
			don't cover the question, say so briefly.
			"""
		// Local: answer as PLAIN TEXT. Small models reliably write good prose but
		// routinely fail to wrap it in a {answer:...} JSON envelope - which surfaces
		// as "didn't return JSON" AND triggers a retry of the whole (slow) prefill,
		// doubling latency for nothing. The prose IS the answer, so skip the wrapper.
		if AIKeyState.shared.activeProvider == .local {
			guard let runner = LocalLLM.runner else { throw AITransformError.localUnavailable }
			let combined = docs.isEmpty ? system : (docs + "\n\n" + system)
			let modelID = LocalModelStore.shared.selectedModelID ?? ""
			// Stream the reply straight into the popover's answer card so the user
			// reads it as it's written, rather than waiting for the whole thing.
			AIDraftState.shared.pendingAnswer = nil
			var acc = ""
			for try await chunk in await runner.completeStreaming(
				modelID: modelID, system: combined, user: prompt)
			{
				acc += chunk
				AIDraftState.shared.pendingAnswer = acc
			}
			let final = MLXLocalLLMRunner.stripThink(acc)
			AIDraftState.shared.pendingAnswer = final
			return final
		}
		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["answer"],
			"properties": [
				"answer": ["type": "string"]
			],
		]
		let raw = try await AIStructuredCall.call(
			system: system,
			cachedSystemPrefix: docs,
			userMessage: prompt,
			schemaName: "answer_question",
			schemaDescription: "Reply to the user's question using the reference docs.",
			jsonSchema: schema,
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini"
		)
		let data = raw.data(using: .utf8) ?? Data()
		let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		return obj["answer"] as? String ?? ""
	}
}
