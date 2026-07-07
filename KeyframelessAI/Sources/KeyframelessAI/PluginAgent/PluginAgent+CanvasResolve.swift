/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Canvas TARGETED routing. Canvas has many layers x many lanes, so dumping
	/// the whole timeline into the planner (as the generic `run` does) is huge and
	/// slow - crippling on local. Instead: classify the intent, then for a
	/// mutation run ONE small "resolve" pass over a compact PROPERTY CATALOG +
	/// the LAYER NAMES (never the timeline, never layer UUIDs) that emits the edit
	/// operations directly. The host turns those into its normal mutation and
	/// applies them through the existing merge path.
	///
	/// Returns the usual `AIPluginResult`: `.answer`, `.createLayers`, or
	/// `.mutation` whose `mutationJSON` is the Canvas-format edit plan
	/// `{ "operations": [{ "layer", "lane", "keyposes": [{ "t", "v": [..] }] }] }`
	/// (t = seconds; one keypose = a constant set, two+ = an animation) that the
	/// host maps to layer ids + clip fractions.
	@MainActor
	static func runCanvasTargetedAsync(
		prompt: String,
		productContext: String,
		laneLabels: [String],
		propertyCatalog: String,
		layerCatalog: String,
		clipDurationSeconds: Double,
		supportsCreate: Bool
	) async throws -> AIPluginResult {
		AIDraftState.shared.routingStatus = AILoc("Reading prompt")
		let classification = try await classify(
			prompt: prompt, productContext: productContext, laneLabels: laneLabels,
			supportsCreate: supportsCreate)

		switch classification.kind {
		case "answer":
			let docs = await renderDocs(for: prompt)
			let reply = try await answerQuestion(
				prompt: prompt, productContext: productContext, docs: docs)
			return AIPluginResult(answer: reply)
		case "create":
			AIDraftState.shared.routingStatus = AILoc("Drawing")
			let draft = try await generateLayers(
				prompt: prompt, productContext: productContext)
			return AIPluginResult(
				createSVG: draft.svg, animatePrompt: draft.animatePrompt)
		case "vague":
			let clarification =
				classification.clarification?.trimmingCharacters(
					in: .whitespacesAndNewlines) ?? ""
			return AIPluginResult(
				answer: clarification.isEmpty
					? "Could you be a bit more specific about what you'd like to change?"
					: clarification)
		default:  // mutation
			AIDraftState.shared.routingStatus = AILoc("Planning edit")
			let plan = try await resolveCanvasEdit(
				prompt: prompt, productContext: productContext,
				propertyCatalog: propertyCatalog, layerCatalog: layerCatalog,
				clipDurationSeconds: clipDurationSeconds,
				enableThinking: classification.complexity == "complex")
			return AIPluginResult(mutationJSON: plan)
		}
	}

	/// The one planning call: a compact catalog in, edit operations out. No
	/// timeline, no UUIDs - just the named properties + layer names, so the
	/// prompt stays small (fast on local) and the model only reasons about the
	/// few lanes it actually needs.
	@MainActor
	static func resolveCanvasEdit(
		prompt: String,
		productContext: String,
		propertyCatalog: String,
		layerCatalog: String,
		clipDurationSeconds: Double,
		enableThinking: Bool
	) async throws -> String {
		let cachedPrefix = """
			You turn a user's request into concrete edit operations for \
			\(productContext). Output ONLY the operations needed - nothing for \
			properties the user didn't mention.

			Each operation targets ONE property of ONE layer:
			- "layer": a layer NAME from the list below, or "selected" (the layer \
			  the user is working on) or "all" (every layer).
			- "lane": the EXACT property label from the catalog below.
			- "keyposes": one or more { "t", "v" }.
			    t = time in SECONDS from the start of the clip.
			    v = the value as a number array (see the catalog for each property's \
			    shape; colours are sRGB [r,g,b,a] 0..1).
			    ONE keypose = a constant value (no animation). TWO OR MORE keyposes \
			    = an animation between those values at those times.
			- "curve" (optional, animations only): the easing - "linear", "easeIn", \
			  "easeOut", "easeInOut" (default, smooth), "bounce", or "elastic".
			- To set a SOLID colour, also emit an operation setting the matching \
			  "... Mode" lane to [0] (Solid).

			Property catalog (label -> meaning / value shape):
			\(propertyCatalog)
			"""
		let system = """
			Layers in this clip:
			\(layerCatalog)

			Clip duration: \(String(format: "%.2f", clipDurationSeconds)) seconds. \
			Keep keypose times within 0..duration. For "draw a line on over the \
			first second" use t=0 and t=1; for the whole clip use 0..duration.
			"""
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
						"required": ["layer", "lane", "keyposes"],
						"properties": [
							"layer": ["type": "string"],
							"lane": ["type": "string"],
							"curve": [
								"type": "string",
								"enum": [
									"", "linear", "easeIn", "easeOut", "easeInOut", "bounce",
									"elastic",
								],
							],
							"keyposes": [
								"type": "array",
								"items": [
									"type": "object",
									"additionalProperties": false,
									"required": ["t", "v"],
									"properties": [
										"t": ["type": "number"],
										"v": ["type": "array", "items": ["type": "number"]],
									],
								],
							],
						],
					],
				]
			],
		]
		let raw = try await AIStructuredCall.call(
			system: system,
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "canvas_edit",
			schemaDescription:
				"The edit operations (layer, property lane, and keyposes) for the request.",
			jsonSchema: schema,
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini",
			enableThinking: enableThinking || AIKeyState.shared.activeProvider == .local
		)
		return raw
	}
}
