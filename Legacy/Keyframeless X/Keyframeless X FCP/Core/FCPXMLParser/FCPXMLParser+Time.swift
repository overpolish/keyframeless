/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension FCPXMLParser {

	static func isEnabled(_ el: XMLElement) -> Bool {
		el.attribute(forName: "enabled")?.stringValue != "0"
	}

	/// Parses FCPXML time values of the form `"N/Ds"`, `"Ns"`, or `"N"`.
	/// Returns seconds as a Double.
	static func parseTime(_ s: String) -> Double {
		let raw = s.hasSuffix("s") ? String(s.dropLast()) : s
		if let slash = raw.firstIndex(of: "/") {
			let num = Double(raw[raw.startIndex..<slash]) ?? 0
			let den = Double(raw[raw.index(after: slash)...]) ?? 1
			return num / den
		}
		return Double(raw) ?? 0
	}

	/// Resolves an element's absolute timeline position by walking up its
	/// XML parents. Stops climbing at primary containers (`sequence`, lane-
	/// less `spine`, `mc-angle`) which carry sequence-absolute offsets;
	/// secondary storylines (`spine` with a `lane`) climb further.
	static func projectTime(of el: XMLElement, tcStart: Double) -> Double {
		let offset = parseTime(el.attribute(forName: "offset")?.stringValue ?? "0s")
		guard let parent = el.parent as? XMLElement else { return offset - tcStart }
		let isPrimaryContainer =
			parent.name == "sequence"
			|| (parent.name == "spine" && parent.attribute(forName: "lane") == nil)
			|| parent.name == "mc-angle"
		guard !isPrimaryContainer else { return offset - tcStart }
		let parentStart = parseTime(parent.attribute(forName: "start")?.stringValue ?? "0s")
		return projectTime(of: parent, tcStart: tcStart) + (offset - parentStart)
	}
}
