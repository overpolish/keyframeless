/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Parse the current timeline JSON into a map of laneLabel -> existing
	/// keyposes (time + values), so Pass 2 can copy values for keyposes Pass
	/// 1 preserved by time. Curves and modulation are decoded separately by
	/// `extractIntervals` — that's Pass 3's territory.
	static func extractLanes(fromTimelineJSON json: String)
		-> [String: [(time: Double, values: [Double])]]
	{
		guard let lanes = decodeLanes(json) else { return [:] }
		var out: [String: [(time: Double, values: [Double])]] = [:]
		for lane in lanes {
			guard let label = lane["label"] as? String,
				let kps = lane["keyposes"] as? [[String: Any]]
			else { continue }
			let parsed: [(time: Double, values: [Double])] = kps.compactMap { kp in
				guard let t = (kp["time"] as? NSNumber)?.doubleValue,
					let vals = kp["values"] as? [NSNumber]
				else { return nil }
				return (time: t, values: vals.map { $0.doubleValue })
			}
			out[label] = parsed
		}
		return out
	}

	/// Parse the current timeline JSON into a map of laneLabel -> existing
	/// intervals (start, end, curve, modulation), so Pass 3 can preserve
	/// existing style choices where a new interval overlaps an old one and
	/// the user hasn't asked to change it.
	static func extractIntervals(fromTimelineJSON json: String)
		-> [String: [(start: Double, end: Double, curve: String, modulation: String)]]
	{
		guard let lanes = decodeLanes(json) else { return [:] }
		var out: [String: [(start: Double, end: Double, curve: String, modulation: String)]] = [:]
		for lane in lanes {
			guard let label = lane["label"] as? String,
				let kps = lane["keyposes"] as? [[String: Any]]
			else { continue }
			var intervals: [(start: Double, end: Double, curve: String, modulation: String)] = []
			for i in 0..<max(0, kps.count - 1) {
				guard let t0 = (kps[i]["time"] as? NSNumber)?.doubleValue,
					let t1 = (kps[i + 1]["time"] as? NSNumber)?.doubleValue,
					let outgoing = kps[i]["outgoing"] as? [String: Any]
				else { continue }
				let linked = (outgoing["endpoints_linked"] as? Bool) ?? false
				let modCode = (outgoing["modulation"] as? NSNumber)?.intValue ?? 0
				let curveCodeVal = (outgoing["curve"] as? NSNumber)?.intValue ?? 3
				let curveName =
					linked ? "hold" : (curveNameByCode[curveCodeVal] ?? "easeInOut")
				let modName = modulationNameByCode[modCode] ?? "none"
				intervals.append(
					(start: t0, end: t1, curve: curveName, modulation: modName))
			}
			out[label] = intervals
		}
		return out
	}

	private static func decodeLanes(_ json: String) -> [[String: Any]]? {
		guard let data = json.data(using: .utf8),
			let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let lanes = obj["lanes"] as? [[String: Any]]
		else { return nil }
		return lanes
	}

	@MainActor
	static func renderDocs() async -> String {
		let entries = await AIKnowledgeRegistry.shared.allEntries()
		guard !entries.isEmpty else { return "REFERENCE DOCS:\n(none registered)" }
		let bySource = Dictionary(grouping: entries) { $0.source }
		var out = "REFERENCE DOCS:\n"
		for (source, items) in bySource.sorted(by: { $0.key < $1.key }) {
			out += "\n# \(source)\n"
			for entry in items {
				out += "\n## \(entry.topic.id) - \(entry.topic.summary)\n"
				out += entry.topic.content + "\n"
			}
		}
		return out
	}
}
