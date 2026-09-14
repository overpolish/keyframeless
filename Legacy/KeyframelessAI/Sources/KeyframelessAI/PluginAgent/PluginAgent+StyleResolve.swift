/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Generator STYLING fast-path. "Make a warm sunset mesh gradient" is one
	/// decision - a Type + a harmonious palette - but the generic timing pipeline
	/// shatters it into Type + one call per colour lane, which crawls on local and
	/// often drops the Type. Instead: ONE focused structured call picks the Type
	/// index and the whole palette together (colours harmonise because they're
	/// chosen at once), then we build the mutation deterministically with the
	/// existing compile helper. Sits beside the timing pipeline - animation
	/// requests still go the full route.
	///
	/// `typeCatalog` is the plugin's "index = name (blurb)" list; `maxColors` the
	/// widest palette it accepts. Returns the standard mutation JSON
	/// (`{ operations: [...] }`) the host already merges - or nil if the model
	/// returned nothing usable (caller falls back to the normal pipeline).
	@MainActor
	static func resolveGeneratorStyle(
		prompt: String,
		productContext: String,
		typeCatalog: String,
		maxColors: Int,
		enableThinking: Bool
	) async throws -> String? {
		let cachedPrefix = """
			You choose an overall LOOK for \(productContext): a generator style \
			(Type) and a colour palette, from one request. Output the single best \
			Type and a harmonious palette - nothing else.

			- "type": the generator style INDEX. Available styles:
			\(typeCatalog)
			  If the request names a style ("mesh", "neon", "grainy", "dithering", \
			  etc.), pick THAT index. Otherwise pick the index whose look best fits \
			  the request.
			- "colors": 2..\(maxColors) colours, each [r, g, b, a] in sRGB 0..1, that \
			  together form the requested look (e.g. a warm sunset = deep \
			  purple/red through orange into pink/gold). Order them as a gradient \
			  ramp - Color 1 is the base/darkest end. Pick a count that suits the \
			  look: more for rich multi-hue gradients, fewer for simple ones.
			"""
		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["type", "colors"],
			"properties": [
				"type": ["type": "integer"],
				"colors": [
					"type": "array",
					"items": [
						"type": "array",
						"items": ["type": "number"],
					],
				],
			],
		]
		let raw = try await AIStructuredCall.call(
			system: "",
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "generator_style",
			schemaDescription:
				"The generator Type index and a harmonious sRGB palette for the requested look.",
			jsonSchema: schema,
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini",
			enableThinking: enableThinking
		)

		guard let data = raw.data(using: .utf8),
			let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }
		let typeIndex = (obj["type"] as? NSNumber)?.intValue ?? 0
		let colorsRaw = obj["colors"] as? [[NSNumber]] ?? []
		let colors: [[Double]] = colorsRaw.map { c in
			var v = c.map { $0.doubleValue }
			while v.count < 4 { v.append(1.0) }  // pad missing alpha
			return Array(v.prefix(4))
		}
		guard !colors.isEmpty else { return nil }

		return buildStyleMutationJSON(typeIndex: typeIndex, colors: colors)
	}

	/// Turn a resolved `{ type, colors }` into the standard mutation JSON: the Type
	/// lane, the Color Count lane, and one Color N lane per swatch - all CONSTANTS
	/// (single keypose), built via `buildOperationJSON` so the shape matches the
	/// merge exactly. Colours beyond a Type's cap are harmless (hidden + clamped
	/// at render), so we set them all and let the host clamp the count.
	private static func buildStyleMutationJSON(typeIndex: Int, colors: [[Double]])
		-> String
	{
		func constantOp(lane: String, values: [Double]) -> [String: Any] {
			let op = TimingOperation(
				lane: lane,
				keyposes: [
					TimingKeypose(time: 0.0, intervalKind: "none", isPreserved: false)
				])
			return buildOperationJSON(
				timingOp: op, values: [values], styles: [],
				existingKeyposes: [], existingIntervals: [])
		}

		var operations: [[String: Any]] = [
			constantOp(lane: "Type", values: [Double(typeIndex)]),
			constantOp(lane: "Color Count", values: [Double(colors.count)]),
		]
		for (i, c) in colors.enumerated() {
			operations.append(constantOp(lane: "Color \(i + 1)", values: c))
		}

		let mutation: [String: Any] = ["operations": operations]
		let data =
			(try? JSONSerialization.data(withJSONObject: mutation))
			?? Data("{\"operations\":[]}".utf8)
		return String(data: data, encoding: .utf8) ?? "{\"operations\":[]}"
	}
}
