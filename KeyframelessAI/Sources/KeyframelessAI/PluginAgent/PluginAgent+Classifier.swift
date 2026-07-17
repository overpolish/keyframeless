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
		prompt: String, productContext: String, laneLabels: [String],
		supportsCreate: Bool = false, supportsCode: Bool = false
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
		// Only a layer-based host (Canvas) can add new shapes; offer the "create"
		// route there, otherwise the kinds are answer/mutation/vague as before.
		let createKindLine =
			supportsCreate
			? "  \"create\"   - user wants to ADD a NEW shape / drawing / layer that doesn't exist yet (\"draw a line\", \"add a circle\", \"put an arrow in the corner\", \"create a box\"). Even when they also describe animating or styling it, choose \"create\" - the new shape must be made first.\n"
			: ""
		// Code authoring (Shader): the LOOK is defined by GLSL source, so a request
		// to change what the shader draws is a code edit, not a lane mutation.
		let codeKindLine =
			supportsCode
			? "  \"code\"     - user wants to WRITE, GENERATE, or EDIT the shader's GLSL source - the visual EFFECT itself, what the shader draws (\"write a shader for a wavy look\", \"make it look like flowing water\", \"give me a plasma effect\", \"add a vignette to the shader\", \"make the ripples bigger\", \"paste a shadertoy that does X\"). Choose this whenever the change is to the appearance/effect produced by the code. Prefer \"code\" over \"mutation\" for look/effect changes; use \"mutation\" only for animating or timing the EXISTING controls (e.g. \"pan the center from left to right\", \"speed it up over 2 seconds\").\n"
			: ""
		let system = """
			Route a user message for \(productContext)'s AI animation and styling \
			assistant. \
			Output a kind, complexity, optional clarification, and optional template \
			fast-path.

			Available lanes: \(laneList)

			kind:
			  "answer"   - user is asking a QUESTION about the tool.
			\(createKindLine)\
			\(codeKindLine)\
			  "mutation" - user wants to CHANGE the content: its animation, its \
			               properties, OR its overall look. It is actionable when it \
			               gives ANY of: a lane, a value, a direction, a time range, a \
			               known modulation/style intent, OR a described visual style, \
			               mood, colour, or palette (e.g. "warm sunset", "ocean tones", \
			               "neon cyberpunk", "make it fiery", "moody and dark", "pastel \
			               gradient"). The assistant picks the concrete lanes and \
			               values itself, so a described LOOK is enough to act on - do \
			               NOT ask for specifics when a style, mood, or colour is given.
			  "vague"    - user wants a change but gives NO actionable content at all: \
			               no lane, value, direction, time range, style, mood, or \
			               colour cue. Examples: "make it cool", "improve it", "do \
			               something", "animate something", "make it better". A \
			               described look / mood / colour scheme is NOT vague.

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
			  "style"    - user wants to set an overall LOOK for a generator: a \
			               colour palette, mood, or a named visual style, with NO \
			               animation. E.g. "warm sunset gradient", "a neon look", \
			               "make it moody and dark", "ocean colours", "a grainy \
			               retro palette". A single STATIC appearance - if the \
			               request animates or names a time range, it is NOT this.
			  "none"     - everything else (multipass will handle).

			template_lane (only when template = "modulate"): EXACT lane label from \
			the Available lanes list above. Match the user's wording to the closest \
			label. Empty string when template = "none".

			template_modulation (only when template = "modulate"):
			  "wiggle"    - default for generic shake/jiggle/wobble/tremor/jitter/ \
			                shimmer/pulse/breathe/vibrate
			  "oscillate" - explicit oscillation, swinging back and forth, sine-like
			  "handheld"  - camera-shake, handheld feel, organic drift

			When uncertain between "answer" and "vague", prefer "vague". But when \
			the message names or describes ANY colour, palette, style, mood, look, \
			value, lane, direction, or time, it is a "mutation" - not "vague".

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
				"kind": [
					"type": "string",
					"enum": ["answer", "mutation", "vague"]
						+ (supportsCreate ? ["create"] : [])
						+ (supportsCode ? ["code"] : []),
				],
				"complexity": ["type": "string", "enum": ["simple", "complex"]],
				"clarification": ["type": "string"],
				"template": ["type": "string", "enum": ["none", "modulate", "style"]],
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

			This is NOT a conversation and you have NO memory of anything before \
			this message - each request is standalone and answered fresh. Never \
			reference an earlier question or answer, never imply continuity ("as I \
			mentioned", "as we discussed", "like before", "still"), and never \
			invite follow-up ("let me know if…", "feel free to ask", "anything \
			else?"). Just answer the single question, self-contained, then stop.
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
			let final = LocalLLM.stripThink(acc)
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
