/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	@MainActor
	static func resolveValues(
		prompt: String,
		productContext: String,
		laneSchemaText: String,
		operation: TimingOperation,
		clipDurationSeconds: Double,
		existingKeyposes: [(time: Double, values: [Double])],
		enableThinking: Bool
	) async throws -> [[Double]] {
		// Only fill values for keyposes Pass 1 marked NEW. Preserved keyposes
		// are filled deterministically from existing state at compile time -
		// the LLM never sees them.
		let newKeyposes = operation.keyposes.enumerated().filter {
			!$0.element.isPreserved
		}
		let n = newKeyposes.count
		if n == 0 { return [] }

		let times = newKeyposes.map { String(format: "%.3f", $0.element.time) }
			.joined(separator: ", ")
		let positionDesc = describeNewKeyposePositions(
			newKeyposes: newKeyposes, allKeyposes: operation.keyposes)
		let neighbourDesc = describeExistingNeighbours(existingKeyposes)

		// Static instructions + lane schema = cacheable. Per-op specifics
		// (lane label, times, neighbours) = dynamic.
		let cachedPrefix = """
			You resolve numeric values for the NEW keyposes of one lane in \
			\(productContext). Preserved (unchanged) keyposes are NOT in your scope; \
			the compile step fills them deterministically. Output ONE value array \
			per new keypose, in the order listed.

			Coordinate space (this is the only context you need):
			\(laneSchemaText)

			Map the user's request to values:
			- "from A to B": first NEW value is A, last NEW value is B.
			- "to X" / "moves to X" / "ends at X" (end state only, no explicit \
			  start): the start NEW keypose value is the lane's DEFAULT from the \
			  coordinate-space description above. The end NEW keypose value is X. \
			  Never copy a neighbour anchor in place of the lane default; never \
			  return start == end for a transition.
			- "wiggle / modulate": all new values are the same (modulation is a \
			  hold).
			- Intermediate new keyposes joined to the next by "hold" copy the \
			  next value.
			"""
		let system = """
			Lane: "\(operation.lane)". You are filling \(n) new keypose(s) at times \
			[\(times)]. Positional context:
			\(positionDesc)

			\(neighbourDesc)

			Output exactly \(n) value array(s) of length matching the lane's \
			component count.
			"""

		// Strict shape: array of N arrays of numbers.
		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["values"],
			"properties": [
				"values": [
					"type": "array",
					"items": [
						"type": "array",
						"items": ["type": "number"],
					],
				]
			],
		]
		let raw = try await AIStructuredCall.call(
			system: system,
			cachedSystemPrefix: cachedPrefix,
			userMessage: prompt,
			schemaName: "resolve_values",
			schemaDescription:
				"Output numeric coordinate values for each keypose of one lane.",
			jsonSchema: schema,
			enableThinking: enableThinking
		)
		let data = raw.data(using: .utf8) ?? Data()
		let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		let valsRaw = obj["values"] as? [[NSNumber]] ?? []
		return valsRaw.map { arr in arr.map { $0.doubleValue } }
	}

	/// Describe each new keypose with its incoming and outgoing interval kinds
	/// plus its position in the full lane layout, so the LLM can reason about
	/// what role each value plays.
	private static func describeNewKeyposePositions(
		newKeyposes: [(offset: Int, element: TimingKeypose)],
		allKeyposes: [TimingKeypose]
	) -> String {
		newKeyposes.map { (origIdx, kp) -> String in
			let prevKind =
				origIdx > 0
				? allKeyposes[origIdx - 1].intervalKind
				: "(none, first)"
			return
				"position \(origIdx) of \(allKeyposes.count): t=\(String(format: "%.3f", kp.time)) "
				+ "(incoming interval=\(prevKind), outgoing interval=\(kp.intervalKind))"
		}.joined(separator: "; ")
	}

	private static func describeExistingNeighbours(
		_ existingKeyposes: [(time: Double, values: [Double])]
	) -> String {
		if existingKeyposes.isEmpty {
			return "No existing values on the lane to anchor to."
		}
		let parts = existingKeyposes.map { kp -> String in
			let valStr = kp.values.map { String(format: "%g", $0) }
				.joined(separator: ", ")
			return "t=\(String(format: "%.3f", kp.time)) -> [\(valStr)]"
		}.joined(separator: "; ")
		return
			"For continuity, the lane's existing values at preserved keyposes are: "
			+ parts
			+ ". When your new keyposes border these, use values that connect smoothly."
	}
}
