/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Result of the layer-creation pass: an SVG document to parse into new
	/// layers, plus an optional follow-up animation request the host runs once
	/// the layers exist (empty when the user only asked to draw something).
	struct LayerDraft {
		let svg: String
		let animatePrompt: String?
	}

	/// Pass for "create" prompts (Canvas only): turn a drawing request into an
	/// SVG document. The host parses it (its existing SVG importer) into editable
	/// vector layers, keeping the stroke/fill the SVG specifies. If the prompt
	/// also asked to animate or reveal the shape, `animatePrompt` carries that as
	/// a normal mutation request to run afterwards.
	@MainActor
	static func generateLayers(
		prompt: String, productContext: String
	) async throws -> LayerDraft {
		let cachedPrefix = """
			You draw new vector shapes for \(productContext) by emitting an SVG \
			document. The host parses the SVG into editable layers and keeps the \
			stroke and fill you specify.

			SVG rules (follow exactly):
			- Output ONE <svg> element with a `viewBox` (e.g. "0 0 100 100"); pick \
			  proportions that suit the shape. Centre the art with a little margin.
			- Allowed elements only: <path>, <rect>, <circle>, <ellipse>, <line>, \
			  <polygon>, <polyline>. No <text>, <image>, <use>, gradients, filters, \
			  CSS or <marker>.
			- Set explicit presentation attributes on every element: `stroke` (a hex \
			  colour like #00cc44 or a CSS colour name), `stroke-width`, and `fill` \
			  ("none" for line art, or a colour to fill). NEVER use `currentColor`.
			- Line art (arrows, lines, open paths, underlines, checkmarks, scribbles) \
			  must use `fill="none"` and a visible `stroke`. Solid shapes set `fill`.
			- ARROWHEADS / endpoint decorations: do NOT draw them as geometry. Request \
			  the plugin's native stroke marker via the element `id`: a LEADING tilde \
			  puts a marker at the line's START, a TRAILING tilde at its END. Marker \
			  names: arrow, circle, square, arrowhead, line. Examples: \
			  `id="arrow~"` (arrowhead at the end), `id="~arrow"` (at the start), \
			  `id="~arrow~"` (both ends), `id="~circle arrow~"` (circle at start, \
			  arrow at end). So for "a line with an arrow", draw ONE open <path>/<line> \
			  with the stroke and `id="arrow~"` - no arrowhead geometry.
			- Use round `stroke-linecap` and `stroke-linejoin` for hand-drawn shapes \
			  unless the user asks otherwise.
			- STROKE WIDTH: make the line clearly visible, NOT a hairline. Use a \
			  `stroke-width` of roughly 3-6% of the viewBox's larger side (e.g. ~3-6 \
			  in a "0 0 100 100" viewBox). Scale it to whatever viewBox you choose.
			- COLOUR: use the EXACT colour the user names - a hex that genuinely \
			  matches the word, NOT a neighbouring colour: red #e23b3b, orange \
			  #ff8c00, yellow #ffd400, green #2ecc40, teal #00b3a4, blue #2563eb, \
			  purple #9c27b0 (a red+blue violet, NOT plain blue), pink #ff5fa2. An \
			  explicit hex from the user always wins. If none is named, pick one \
			  sensible colour.

			animate: set true ONLY when the user asked for motion or a reveal over \
			time (e.g. "drawing on", "fade in", "slide in", "spin"). Put a short, \
			standalone instruction in animation_prompt describing it (refer to "the \
			shape"), e.g. "reveal the stroke drawing on over the first second". When \
			the user only asked to draw a static shape, set animate=false and \
			animation_prompt="".
			"""
		// Local: emit the SVG as PLAIN TEXT, not wrapped in JSON. Small models
		// reliably write an SVG but routinely mis-escape it inside a JSON string
		// (e.g. `\<`), which then fails to parse. So skip the envelope: ask for
		// the raw SVG, extract <svg>...</svg>, and decide animation from the
		// prompt's wording (the follow-up pass runs the original prompt).
		if AIKeyState.shared.activeProvider == .local {
			guard let runner = LocalLLM.runner else {
				throw AITransformError.localUnavailable
			}
			let modelID = LocalModelStore.shared.selectedModelID ?? ""
			let sys =
				cachedPrefix
				+ "\n\nOutput ONLY the SVG document: start with `<svg` and end with "
				+ "`</svg>`. No JSON, no code fences, no commentary."
			let text = LocalLLM.stripThink(
				try await runner.complete(
					modelID: modelID, system: sys, user: prompt,
					jsonSchemaJSON: nil, enableThinking: true))
			return LayerDraft(
				svg: extractSVGDocument(text),
				animatePrompt: promptRequestsAnimation(prompt) ? prompt : nil)
		}
		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["svg", "animate", "animation_prompt"],
			"properties": [
				"svg": ["type": "string"],
				"animate": ["type": "boolean"],
				"animation_prompt": ["type": "string"],
			],
		]
		let raw = try await AIStructuredCall.call(
			system: "Produce the SVG for the user's request.",
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "draw_layers",
			schemaDescription:
				"Emit an SVG document for the requested shape, and whether to animate it.",
			jsonSchema: schema,
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini",
			// Local small models benefit from reasoning before emitting a whole
			// SVG; cloud models one-shot it under the grammar constraint.
			enableThinking: AIKeyState.shared.activeProvider == .local
		)
		let data = raw.data(using: .utf8) ?? Data()
		let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		let svg = (obj["svg"] as? String ?? "").trimmingCharacters(
			in: .whitespacesAndNewlines)
		let animate = obj["animate"] as? Bool ?? false
		let animPrompt = (obj["animation_prompt"] as? String ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return LayerDraft(
			svg: svg, animatePrompt: (animate && !animPrompt.isEmpty) ? animPrompt : nil)
	}

	/// Pull the `<svg>...</svg>` document out of a free-text reply (a local model
	/// may add fences or stray words around it). Falls back to the trimmed input.
	private static func extractSVGDocument(_ s: String) -> String {
		let lower = s.lowercased()
		guard let open = lower.range(of: "<svg"),
			let close = lower.range(of: "</svg>", options: .backwards)
		else {
			return s.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return String(s[open.lowerBound..<close.upperBound])
	}

	/// True when the prompt asks for motion or a timed reveal (so the new shape
	/// should also be animated after it's drawn). Deliberately narrow - a false
	/// positive sends a static draw through a pointless animate pass.
	private static func promptRequestsAnimation(_ prompt: String) -> Bool {
		let p = prompt.lowercased()
		let cues = [
			"draw on", "drawing on", "draw-on", "write on", "writing on",
			"reveal", "animat", "fade", "spin", "rotate", "slide", "grow",
			"shrink", "pop in", "bounce", "wipe", "appear", "over the first",
			"over 1", "over a", "seconds", "second",
		]
		return cues.contains { p.contains($0) }
	}
}
