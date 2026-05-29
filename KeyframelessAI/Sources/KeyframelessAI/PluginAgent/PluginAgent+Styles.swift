/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Pass 3 output: one (curve, modulation) pick per outgoing interval.
	/// For "hold" intervals the curve is ignored (forced to the hold encoding
	/// at compile time); for "transition" intervals the modulation is ignored
	/// (forced to "none").
	struct StyleChoice {
		let curve: String  // linear | easeIn | easeOut | easeInOut | elastic | bounce
		let modulation: String  // none | wiggle | oscillate | handheld
	}

	/// One entry per outgoing interval (excluding the final "none" interval).
	@MainActor
	static func planCurves(
		prompt: String,
		productContext: String,
		operation: TimingOperation,
		existingIntervals: [(start: Double, end: Double, curve: String, modulation: String)]
	) async throws -> [StyleChoice] {
		let intervals = (0..<(operation.keyposes.count - 1)).map { i in
			(
				start: operation.keyposes[i].time,
				end: operation.keyposes[i + 1].time,
				kind: operation.keyposes[i].intervalKind
			)
		}
		if intervals.isEmpty { return [] }
		let intervalDesc = intervals.enumerated().map { (i, iv) -> String in
			"#\(i): [\(String(format: "%.3f", iv.start))..\(String(format: "%.3f", iv.end))] \(iv.kind)"
		}.joined(separator: "; ")
		let existingDesc = describeExistingIntervals(existingIntervals)

		let cachedPrefix = """
			Pick the easing curve and modulation for each interval of one lane of \
			an animation in \(productContext). Times and structure are already \
			decided; values are filled by another pass.

			Curves: linear, easeIn, easeOut, easeInOut, elastic, bounce.
			    Default easeInOut for transitions unless the user says otherwise.
			    For a "transition" interval pick the curve; the modulation will be \
			    ignored.

			Modulation: none, wiggle, oscillate, handheld.
			    Default none for holds unless the user says otherwise.
			    For a "hold" interval pick the modulation; the curve will be ignored \
			    (always behaves as a hold).

			User prompt is below for aesthetic intent ("with bounce", "smooth", \
			"wiggle", etc.).
			"""
		let system = """
			Lane: "\(operation.lane)". Intervals to fill (output exactly \
			\(intervals.count) entries, in order):
			\(intervalDesc)

			\(existingDesc)
			"""

		let curves = ["linear", "easeIn", "easeOut", "easeInOut", "elastic", "bounce"]
		let modulations = ["none", "wiggle", "oscillate", "handheld"]
		let entry: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["curve", "modulation"],
			"properties": [
				"curve": ["type": "string", "enum": curves],
				"modulation": ["type": "string", "enum": modulations],
			],
		]
		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["intervals"],
			"properties": [
				"intervals": ["type": "array", "items": entry]
			],
		]
		// Style picking is enum-bounded and not arithmetic; cheap models handle
		// it fine without extended thinking. Keeps cost roughly 3-5x lower than
		// running Sonnet/o4-mini here.
		let raw = try await AIStructuredCall.call(
			system: system,
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "plan_curves",
			schemaDescription:
				"Pick the easing curve (for transitions) and modulation (for holds) per interval.",
			jsonSchema: schema,
			modelOverride: AIKeyState.shared.activeProvider == .anthropic
				? "claude-haiku-4-5-20251001"
				: "gpt-4o-mini",
			enableThinking: false
		)
		let data = raw.data(using: .utf8) ?? Data()
		let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		let arr = obj["intervals"] as? [[String: Any]] ?? []
		return arr.compactMap { d in
			guard let curve = d["curve"] as? String,
				let mod = d["modulation"] as? String
			else { return nil }
			return StyleChoice(curve: curve, modulation: mod)
		}
	}

	private static func describeExistingIntervals(
		_ existingIntervals: [(start: Double, end: Double, curve: String, modulation: String)]
	) -> String {
		if existingIntervals.isEmpty {
			return
				"No prior curves/modulation on this lane - pick defaults unless the user says otherwise."
		}
		let parts = existingIntervals.map { iv -> String in
			"[\(String(format: "%.3f", iv.start))..\(String(format: "%.3f", iv.end))] curve=\(iv.curve) mod=\(iv.modulation)"
		}.joined(separator: "; ")
		return
			"Existing curves/modulation BEFORE this edit: \(parts). "
			+ "For any new interval whose time range overlaps an existing one AND "
			+ "the user did not ask to change easing/modulation, REUSE the existing "
			+ "curve/modulation choice."
	}
}
