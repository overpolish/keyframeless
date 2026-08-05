/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	/// Parse the current timeline JSON into a map of laneLabel -> existing
	/// keyposes (time + values), so Pass 2 can copy values for keyposes Pass
	/// 1 preserved by time. Curves and modulation are decoded separately by
	/// `extractIntervals` - that's Pass 3's territory.
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

	static func decodeLanes(_ json: String) -> [[String: Any]]? {
		guard let data = json.data(using: .utf8),
			let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let lanes = obj["lanes"] as? [[String: Any]]
		else { return nil }
		return lanes
	}

	/// Strip a timeline JSON down to what the passes actually read: each lane's
	/// `label` + `keyposes` (times / values / outgoing). Drops all build-time
	/// lane metadata - visibility rules, component ranges, choice labels,
	/// category, controller maps, etc. - which no pass consumes but which bloats
	/// the Pass 1 prompt (and, on device, its prefill time / memory). The host
	/// keeps the full JSON for the merge; this compact form is prompt-only.
	static func compactTimelineForAI(_ json: String) -> String {
		guard let lanes = decodeLanes(json) else { return json }
		let slim: [[String: Any]] = lanes.compactMap { lane in
			guard let label = lane["label"] else { return nil }
			var out: [String: Any] = ["label": label]
			if let kps = lane["keyposes"] { out["keyposes"] = kps }
			return out
		}
		guard
			let data = try? JSONSerialization.data(
				withJSONObject: ["lanes": slim]),
			let s = String(data: data, encoding: .utf8)
		else { return json }
		return s
	}

	@MainActor
	static func renderDocs(for prompt: String) async -> String {
		// Local models prefill slowly, so retrieve only the topics relevant to the
		// prompt instead of dumping the whole knowledge base (a 10k-token jam costs
		// ~70s of prefill on device). Cloud has fast prefill + a big context window,
		// so it keeps the full docs for maximum answer quality.
		let entries =
			AIKeyState.shared.activeProvider == .local
			? await AIKnowledgeRegistry.shared.relevantEntries(to: prompt, limit: 2)
			: await AIKnowledgeRegistry.shared.allEntries()
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
