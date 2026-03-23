/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

struct PublishedParameter: Identifiable, Codable, Equatable {
	var id: String { "\(objectID)/\(channel)" }
	let name: String
	let objectID: String
	let channel: String
	let kind: ParamKind
	let defaultR: Double?
	let defaultG: Double?
	let defaultB: Double?
	let defaultSlider: Double?

	enum ParamKind: String, Codable, Equatable {
		case color
		case slider
		case animation
		case unsupported
	}

	var isToggleable: Bool { kind == .color || kind == .slider }

	private static let animationNames: Set<String> = ["Words In", "Animate On"]

	struct ParseResult {
		let customParams: [PublishedParameter]
		let hasPerWordAnimation: Bool
	}

	static func parseAll(from motiURL: URL) -> ParseResult {
		guard let data = try? Data(contentsOf: motiURL, options: .mappedIfSafe),
			let content = String(data: data, encoding: .utf8),
			let pubStart = content.range(of: "<publishSettings>"),
			let pubEnd = content.range(of: "</publishSettings>")
		else { return ParseResult(customParams: [], hasPerWordAnimation: false) }

		let block = String(content[pubStart.lowerBound..<pubEnd.upperBound])
		let pattern = #"<target\s+object="(\d+)"\s+channel="([^"]+)"\s+name="([^"]+)""#
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return ParseResult(customParams: [], hasPerWordAnimation: false)
		}

		let matches = regex.matches(in: block, range: NSRange(block.startIndex..., in: block))
		var customParams: [PublishedParameter] = []
		var hasPerWord = false

		for match in matches {
			let objectID = (block as NSString).substring(with: match.range(at: 1))
			let channel = (block as NSString).substring(with: match.range(at: 2))
			let name = (block as NSString).substring(with: match.range(at: 3))

			if animationNames.contains(name) {
				hasPerWord = true
				continue
			}

			let info = detectKindAndDefaults(objectID: objectID, channel: channel, in: content)
			customParams.append(
				PublishedParameter(
					name: name, objectID: objectID, channel: channel, kind: info.kind,
					defaultR: info.r, defaultG: info.g, defaultB: info.b,
					defaultSlider: info.slider))
		}

		return ParseResult(customParams: customParams, hasPerWordAnimation: hasPerWord)
	}

	private struct DetectionResult {
		let kind: ParamKind
		var r: Double?
		var g: Double?
		var b: Double?
		var slider: Double?
	}

	private static func detectKindAndDefaults(
		objectID: String, channel: String, in content: String
	) -> DetectionResult {
		let ids = channel.replacingOccurrences(of: "./", with: "")
			.split(separator: "/").map(String.init)
		guard !ids.isEmpty else { return DetectionResult(kind: .unsupported) }

		let nodePattern = "scenenode[^>]*\\sid=\"\(objectID)\""
		guard let nodeRegex = try? NSRegularExpression(pattern: nodePattern),
			let nodeMatch = nodeRegex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return DetectionResult(kind: .unsupported) }

		var searchStart = content.index(content.startIndex, offsetBy: nodeMatch.range.location)
		var depth = 0
		for pathID in ids {
			let paramTag = "parameter[^>]*\\sid=\"\(pathID)\""
			guard let paramRegex = try? NSRegularExpression(pattern: paramTag) else {
				return DetectionResult(kind: .unsupported)
			}
			let searchRange = NSRange(searchStart..., in: content)
			guard let paramMatch = paramRegex.firstMatch(in: content, range: searchRange) else {
				if depth >= ids.count - 1 { return DetectionResult(kind: .slider) }
				return DetectionResult(kind: .unsupported)
			}
			searchStart = content.index(
				content.startIndex, offsetBy: paramMatch.range.location)
			depth += 1
		}

		let remaining = content[searchStart...]
		let lookahead = String(remaining.prefix(2000))

		if let rgb = extractColorDefaults(from: lookahead) {
			return DetectionResult(kind: .color, r: rgb.r, g: rgb.g, b: rgb.b)
		}

		let sliderDefault = extractSliderDefault(leafID: ids.last ?? "", from: lookahead)
		return DetectionResult(kind: .slider, slider: sliderDefault)
	}

	private static func extractColorDefaults(from text: String) -> (
		r: Double, g: Double, b: Double
	)? {
		guard text.contains("name=\"Red\""), text.contains("name=\"Green\""),
			text.contains("name=\"Blue\"")
		else { return nil }

		func val(for name: String) -> Double? {
			let p = "name=\"\(name)\"[^>]*value=\"([^\"]+)\""
			guard let rx = try? NSRegularExpression(pattern: p),
				let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
			else { return nil }
			return Double((text as NSString).substring(with: m.range(at: 1)))
		}

		guard let r = val(for: "Red"), let g = val(for: "Green"), let b = val(for: "Blue")
		else { return nil }
		return (r, g, b)
	}

	private static func extractSliderDefault(leafID: String, from text: String) -> Double? {
		let p = "<parameter[^>]*\\sid=\"\(leafID)\"[^>]*(?:default|value)=\"([^\"]+)\""
		guard let rx = try? NSRegularExpression(pattern: p),
			let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
		else { return nil }
		return Double((text as NSString).substring(with: m.range(at: 1)))
	}
}
