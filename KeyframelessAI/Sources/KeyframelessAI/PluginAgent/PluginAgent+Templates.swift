/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Build a modulation mutation using the lane + kind the classifier
	/// already resolved from natural language. Returns nil when the lane
	/// label doesn't match anything we know about or when the lane has no
	/// existing keypose to copy a held value from.
	@MainActor
	static func buildModulateTemplate(
		lane: String, modulation: String, currentTimelineJSON: String
	) -> String? {
		let lanes = extractLanes(fromTimelineJSON: currentTimelineJSON)
		// Case-insensitive lane lookup so minor classifier-output casing
		// drift doesn't drop the fast-path.
		guard
			let (matchedLabel, kps) = lanes.first(where: {
				$0.key.compare(lane, options: .caseInsensitive) == .orderedSame
			})
		else { return nil }
		guard let first = kps.first else { return nil }
		let kind = modulation.isEmpty ? "wiggle" : modulation
		let modCode = modulationCode[kind] ?? 1
		let outgoing: [String: Any] = [
			"curve": 0,
			"endpoints_linked": true,
			"intensity": 1.0,
			"frequency": 0.5,
			"modulation": modCode,
			"modulation_intensity": 0.5,
			"modulation_frequency": 0.5,
			"modulation_linked": true,
		]
		let kp0: [String: Any] = [
			"time": 0.0, "values": first.values, "outgoing": outgoing,
		]
		let kp1: [String: Any] = [
			"time": 1.0, "values": first.values, "outgoing": NSNull(),
		]
		let mutation: [String: Any] = [
			"operations": [
				[
					"lane": matchedLabel,
					"keyposes": [kp0, kp1],
					"hold_shape": 0,
				]
			]
		]
		guard let data = try? JSONSerialization.data(withJSONObject: mutation),
			let str = String(data: data, encoding: .utf8)
		else { return nil }
		return str
	}

	/// Collect lane labels for the classifier prompt. Prefer labels from the
	/// live timeline state (those have known component counts and values).
	/// Fall back to scanning the schema text for headings of the form
	/// `Lane: "Label"` when the timeline has no animation yet.
	static func laneLabels(
		fromTimelineJSON json: String, fallbackSchemaText: String
	) -> [String] {
		let fromTimeline = extractLanes(fromTimelineJSON: json)
		if !fromTimeline.isEmpty {
			return Array(fromTimeline.keys).sorted()
		}
		return parseLabelsFromSchemaText(fallbackSchemaText)
	}

	/// Heuristic: pull anything between straight quotes on lines that look
	/// like a lane heading. Good enough — the classifier rejects ambiguous
	/// matches downstream.
	private static func parseLabelsFromSchemaText(_ schemaText: String) -> [String] {
		var seen = Set<String>()
		var out: [String] = []
		for line in schemaText.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard let openIdx = trimmed.firstIndex(of: "\"") else { continue }
			let afterOpen = trimmed.index(after: openIdx)
			guard afterOpen < trimmed.endIndex,
				let closeIdx = trimmed[afterOpen...].firstIndex(of: "\"")
			else { continue }
			let label = String(trimmed[afterOpen..<closeIdx])
			if !label.isEmpty, seen.insert(label).inserted {
				out.append(label)
			}
		}
		return out
	}
}
