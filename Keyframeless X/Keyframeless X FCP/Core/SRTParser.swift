/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

struct SRTCue: Codable {
	let startTime: Double
	let endTime: Double
	let text: String
}

enum SRTParser {

	static func parse(_ raw: String) -> [SRTCue] {
		let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
		let blocks = normalized.components(separatedBy: "\n\n")
		var cues: [SRTCue] = []
		for block in blocks {
			let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(
				String.init)
			guard !lines.isEmpty else { continue }
			// First line may be cue index, second is timing; otherwise first IS timing.
			var idx = 0
			if !lines[idx].contains("-->") { idx += 1 }
			guard idx < lines.count else { continue }
			guard let times = parseTimingLine(lines[idx]) else { continue }
			let textLines = lines.dropFirst(idx + 1)
				.map(stripTags)
				.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			guard !textLines.isEmpty else { continue }
			cues.append(
				SRTCue(
					startTime: times.0, endTime: times.1,
					text: textLines.joined(separator: " ")))
		}
		return cues.sorted { $0.startTime < $1.startTime }
	}

	private static func parseTimingLine(_ line: String) -> (Double, Double)? {
		let parts = line.components(separatedBy: "-->")
		guard parts.count == 2 else { return nil }
		guard let start = parseTimestamp(parts[0]) else { return nil }
		guard let end = parseTimestamp(parts[1]) else { return nil }
		return (start, end)
	}

	private static func parseTimestamp(_ raw: String) -> Double? {
		let trimmed = raw.trimmingCharacters(in: .whitespaces)
			.replacingOccurrences(of: ",", with: ".")
		let parts = trimmed.split(separator: ":")
		guard parts.count == 3 else { return nil }
		guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
			return nil
		}
		return h * 3600 + m * 60 + s
	}

	private static func stripTags(_ text: String) -> String {
		var result = text
		let patterns = ["<[^>]+>", "\\{[^}]+\\}"]
		for pattern in patterns {
			if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
				let range = NSRange(result.startIndex..., in: result)
				result = regex.stringByReplacingMatches(
					in: result, options: [], range: range, withTemplate: "")
			}
		}
		return result
	}
}
