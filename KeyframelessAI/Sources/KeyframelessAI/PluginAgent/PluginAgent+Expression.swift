/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Pass for "expression" prompts: turn a request for formula-driven / procedural
	/// / cross-clip motion into one expression per target lane. Returns JSON
	/// `{ "operations": [{ "lane": "...", "expression": "..." }] }`; the host sets
	/// each lane's `linkExpression`. Cross-clip refs come back in the friendly
	/// `${Clip.Param}` form (from `availableSources`), which the host translates to
	/// stored ids. When a target lane already carries an expression the model EDITS
	/// it rather than replacing it wholesale.
	@MainActor
	static func generateExpressionOps(
		prompt: String, productContext: String, currentTimelineJSON: String,
		availableSources: String, laneLabels: [String]
	) async throws -> String {
		let docs = await expressionDocs()
		let laneCtx = laneExpressionContext(
			fromTimelineJSON: currentTimelineJSON, laneLabels: laneLabels)
		let trimmedSources = availableSources.trimmingCharacters(
			in: .whitespacesAndNewlines)
		let hasSources = !trimmedSources.isEmpty && trimmedSources != "[]"

		let rules = """
			You write EXPRESSIONS for \(productContext). An expression drives ONE \
			property from a formula, evaluated every frame. Follow the EXPRESSION \
			REFERENCE above exactly - only the variables and functions it lists exist.

			Rules (follow exactly):
			- Pick the target property (lane) from the AVAILABLE LANES list and answer \
			  with its quoted id EXACTLY as listed - that is the property's identity, \
			  which is not always the name shown in the inspector. A lane that isn't \
			  listed cannot be driven. Emit one operation per lane you drive; drive \
			  several only when the request clearly spans several (e.g. "wobble X and \
			  Y differently").
			- `value` is the lane's OWN current value - build on it (`value + ...`, \
			  `value * ...`); do not throw it away unless the user wants an absolute \
			  formula. Never invent a keyframed value.
			- Time: `t` is ABSOLUTE project seconds (continuous, not per-clip). For \
			  motion that starts with the clip use `ct` (seconds since clip start) or \
			  `progress` (0..1 across the clip). Easing functions and smoothstep need a \
			  0..1 input - feed `progress`, `clamp(ct,0,1)`, or `pingpong`/`repeat`, \
			  never raw `t`. Angles are radians.
			- Multi-component lanes: `value` is the whole vector; read parts with \
			  `value.x/.y/.z/.w`; rebuild with `vec2/3/4(...)` to drive axes apart.
			- Cross-clip: reference another clip's parameter ONLY as `${Clip.Param}` \
			  using names EXACTLY as they appear in AVAILABLE SOURCES below. Never \
			  invent a clip or param name. If the user asks to link to a clip that is \
			  not listed, write the closest self-referential formula instead.
			- If a lane already has an expression (shown below), EDIT it to satisfy the \
			  request rather than discarding it.
			- Output ONLY the operations. Keep each expression minimal and correct.
			"""
		let cachedPrefix = docs.isEmpty ? rules : (docs + "\n\n" + rules)

		var context = "AVAILABLE LANES (drive these by their quoted id):\n" + laneCtx
		if hasSources {
			context +=
				"\n\nAVAILABLE SOURCES (other clips you may reference as "
				+ "${Clip.Param}; use these names verbatim):\n" + trimmedSources
		} else {
			context +=
				"\n\nAVAILABLE SOURCES: none - no other clips are available to "
				+ "reference, so use only self-referential formulas (value, t, "
				+ "progress, ct, functions)."
		}

		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["operations"],
			"properties": [
				"operations": [
					"type": "array",
					"items": [
						"type": "object",
						"additionalProperties": false,
						"required": ["lane", "expression"],
						"properties": [
							"lane": ["type": "string"],
							"expression": ["type": "string"],
						],
					],
				]
			],
		]
		let raw = try await AIStructuredCall.call(
			system: context,
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "author_expression",
			schemaDescription:
				"Emit one formula-driven expression per target property lane.",
			jsonSchema: schema,
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini",
			enableThinking: true
		)
		return raw
	}

	/// The full text of the `expressions` reference topic the host registered, so
	/// the model uses only real variables/functions and correct conventions. Empty
	/// if the host registered no docs.
	@MainActor
	private static func expressionDocs() async -> String {
		// `expressions` is the prose guide; `expression-functions` is the exhaustive
		// variable/function list generated from the editor's own catalog. Both, or
		// the model invents plausible-looking functions the evaluator doesn't have.
		let wanted: Set<String> = ["expressions", "expression-functions"]
		let entries = await AIKnowledgeRegistry.shared.allEntries()
			.filter { wanted.contains($0.topic.id) }
		guard !entries.isEmpty else { return "" }
		var out = "EXPRESSION REFERENCE (follow these conventions exactly):\n"
		for e in entries.sorted(by: { $0.topic.id < $1.topic.id }) {
			out += "\n" + e.topic.content + "\n"
		}
		return out
	}

	/// One line per available lane: its id (the lane KEY the host matches on, which
	/// for a directive-derived control is the uniform name, not the display label),
	/// the label when it differs, the component count, and the current expression
	/// (for edit-vs-fresh), parsed from the timeline JSON. Falls back to the bare
	/// label list when the JSON has no per-lane detail.
	private static func laneExpressionContext(
		fromTimelineJSON json: String, laneLabels: [String]
	) -> String {
		let lanes = decodeLanes(json) ?? []
		var byLabel: [String: (key: String, components: Int, expr: String)] = [:]
		for lane in lanes {
			guard let label = lane["label"] as? String else { continue }
			var comps = 1
			if let kps = lane["keyposes"] as? [[String: Any]],
				let first = kps.first,
				let vals = first["values"] as? [Any]
			{
				comps = max(1, vals.count)
			}
			let expr = (lane["link_expr"] as? String) ?? ""
			byLabel[label] = ((lane["key"] as? String) ?? label, comps, expr)
		}
		let labels = laneLabels.isEmpty ? Array(byLabel.keys) : laneLabels
		if labels.isEmpty { return "(no lanes available)" }
		return labels.map { label -> String in
			let info = byLabel[label]
			let id = info?.key ?? label
			// Only worth the extra words when identity and display disagree.
			let labelText = id == label ? "" : " (shown as \"\(label)\")"
			let comps = info?.components ?? 1
			let compText = comps > 1 ? " (\(comps) components)" : ""
			let expr = info?.expr ?? ""
			let exprText =
				expr.isEmpty ? "" : ", current expression: \(expr)"
			return "- \"\(id)\"\(labelText)\(compText)\(exprText)"
		}.joined(separator: "\n")
	}
}
