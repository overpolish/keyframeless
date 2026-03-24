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
	var kind: ParamKind
	var isProjectRoot: Bool = false
	var parentLayerID: String?
	var defaultR: Double?
	var defaultG: Double?
	var defaultB: Double?

	enum ParamKind: String, Codable, Equatable {
		case off
		case color
		case slider
		case toggle
		case animation

		init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = ParamKind(rawValue: raw) ?? .off
		}
	}

	var isToggleable: Bool { kind == .color || kind == .slider || kind == .toggle }

	var channelPath: String {
		channel.hasPrefix("./") ? String(channel.dropFirst(2)) : channel
	}

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

		let projectRootID = extractProjectRootID(from: content)

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

			let channelPath = channel.hasPrefix("./") ? String(channel.dropFirst(2)) : channel
			let rgb = extractColorDefaults(
				objectID: objectID, channelPath: channelPath, in: content)
			let layerID = findContainingLayerID(for: objectID, in: content)
			customParams.append(
				PublishedParameter(
					name: name, objectID: objectID, channel: channel, kind: .off,
					isProjectRoot: objectID == projectRootID,
					parentLayerID: layerID,
					defaultR: rgb?.r, defaultG: rgb?.g, defaultB: rgb?.b))
		}

		return ParseResult(customParams: customParams, hasPerWordAnimation: hasPerWord)
	}

	private static func extractColorDefaults(
		objectID: String, channelPath: String, in content: String
	) -> (r: Double, g: Double, b: Double)? {
		let ids = channelPath.split(separator: "/").map(String.init)
		guard !ids.isEmpty else { return nil }

		let nodePattern = "scenenode[^>]*\\sid=\"\(objectID)\""
		guard let nodeRegex = try? NSRegularExpression(pattern: nodePattern),
			let nodeMatch = nodeRegex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }

		var searchStart = content.index(content.startIndex, offsetBy: nodeMatch.range.location)
		for pathID in ids {
			let paramTag = "parameter[^>]*\\sid=\"\(pathID)\""
			guard let paramRegex = try? NSRegularExpression(pattern: paramTag),
				let paramMatch = paramRegex.firstMatch(
					in: content, range: NSRange(searchStart..., in: content))
			else { return nil }
			searchStart = content.index(content.startIndex, offsetBy: paramMatch.range.location)
		}

		let lookahead = String(content[searchStart...].prefix(2000))
		guard lookahead.contains("name=\"Red\""), lookahead.contains("name=\"Green\""),
			lookahead.contains("name=\"Blue\"")
		else { return nil }

		func val(for name: String) -> Double? {
			let p = "name=\"\(name)\"[^>]*value=\"([^\"]+)\""
			guard let rx = try? NSRegularExpression(pattern: p),
				let m = rx.firstMatch(
					in: lookahead, range: NSRange(lookahead.startIndex..., in: lookahead))
			else { return nil }
			return Double((lookahead as NSString).substring(with: m.range(at: 1)))
		}

		guard let r = val(for: "Red"), let g = val(for: "Green"), let b = val(for: "Blue")
		else { return nil }
		return (r, g, b)
	}

	private static func extractProjectRootID(from content: String) -> String? {
		let pattern = #"<scenenode[^>]*\sid="(\d+)"[^>]*factoryID="13""#
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }
		return (content as NSString).substring(with: match.range(at: 1))
	}

	private static func findContainingLayerID(for objectID: String, in content: String) -> String? {
		let objPattern = "id=\"\(objectID)\""
		guard let objRegex = try? NSRegularExpression(pattern: objPattern),
			let objMatch = objRegex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }
		let beforeObj = (content as NSString).substring(to: objMatch.range.location)
		let layerPattern = "<layer[^>]*\\sid=\"(\\d+)\""
		guard let layerRegex = try? NSRegularExpression(pattern: layerPattern) else { return nil }
		let matches = layerRegex.matches(
			in: beforeObj, range: NSRange(beforeObj.startIndex..., in: beforeObj))
		return matches.last.map { (beforeObj as NSString).substring(with: $0.range(at: 1)) }
	}
}
