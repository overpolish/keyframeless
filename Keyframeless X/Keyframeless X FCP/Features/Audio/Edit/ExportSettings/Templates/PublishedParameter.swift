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
	var parentScenenodeID: String?
	var defaultR: Double?
	var defaultG: Double?
	var defaultB: Double?
	var defaultFont: String?

	enum ParamKind: String, Codable, Equatable {
		case off
		case color
		case slider
		case toggle
		case animation
		case font

		init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			switch raw {
			case "fontProject", "fontCustom": self = .font
			default: self = ParamKind(rawValue: raw) ?? .off
			}
		}
	}

	var isFont: Bool { kind == .font }
	var isToggleable: Bool { kind == .color || kind == .slider || kind == .toggle }

	var channelPath: String {
		channel.hasPrefix("./") ? String(channel.dropFirst(2)) : channel
	}

	var channelParamID: String {
		channelPath.split(separator: "/").last.map(String.init) ?? channelPath
	}

	var effectValueKey: String {
		if isProjectRoot {
			return "9999/\(objectID)/\(channelPath)"
		} else if let parentScenenode = parentScenenodeID {
			return
				"9999/\(parentLayerID ?? "10003")/\(parentScenenode)/4/\(objectID)/\(channelPath)"
		} else {
			return "9999/\(parentLayerID ?? "10003")/\(objectID)/\(channelPath)"
		}
	}

	private static let animationNames: Set<String> = ["Words In", "Animate On"]

	struct TextOzmlInfo {
		let key: String
		let ozml: String
		let defaultText: String
		let styleID: String?
	}

	struct ParseResult {
		let customParams: [PublishedParameter]
		let hasPerWordAnimation: Bool
		var textOzml: TextOzmlInfo?
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
			let fontDefault = extractFontDefault(
				objectID: objectID, channelPath: channelPath, in: content)
			let isFont = fontDefault != nil
			let rgb =
				isFont
				? nil
				: extractColorDefaults(
					objectID: objectID, channelPath: channelPath, in: content)
			let layerID = findContainingLayerID(for: objectID, in: content)
			let parentScenenode = findParentScenenodeID(for: objectID, in: content)
			customParams.append(
				PublishedParameter(
					name: name, objectID: objectID, channel: channel,
					kind: isFont ? .font : .off,
					isProjectRoot: objectID == projectRootID,
					parentLayerID: layerID, parentScenenodeID: parentScenenode,
					defaultR: rgb?.r, defaultG: rgb?.g, defaultB: rgb?.b,
					defaultFont: fontDefault))
		}

		let textOzml = extractTextOzml(from: content)
		return ParseResult(
			customParams: customParams, hasPerWordAnimation: hasPerWord, textOzml: textOzml)
	}

	private static func extractFontDefault(
		objectID: String, channelPath: String, in content: String
	) -> String? {
		let ids = channelPath.split(separator: "/").map(String.init)
		guard !ids.isEmpty else { return nil }

		let nodePattern = "\\bid=\"\(objectID)\""
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

		let lookahead = String(content[searchStart...].prefix(500))
		let fontPattern = "<font>([^<]+)</font>"
		guard let fontRegex = try? NSRegularExpression(pattern: fontPattern),
			let fontMatch = fontRegex.firstMatch(
				in: lookahead, range: NSRange(lookahead.startIndex..., in: lookahead))
		else { return nil }
		return (lookahead as NSString).substring(with: fontMatch.range(at: 1))
	}

	private static func extractColorDefaults(
		objectID: String, channelPath: String, in content: String
	) -> (r: Double, g: Double, b: Double)? {
		let ids = channelPath.split(separator: "/").map(String.init)
		guard !ids.isEmpty else { return nil }

		let nodePattern = "\\bid=\"\(objectID)\""
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
		guard
			lookahead.contains("name=\"Red\"") || lookahead.contains("name=\"Green\"")
				|| lookahead.contains("name=\"Blue\"")
		else { return nil }

		func val(for name: String) -> Double? {
			let p = "name=\"\(name)\"[^>]*value=\"([^\"]+)\""
			guard let rx = try? NSRegularExpression(pattern: p),
				let m = rx.firstMatch(
					in: lookahead, range: NSRange(lookahead.startIndex..., in: lookahead))
			else { return nil }
			return Double((lookahead as NSString).substring(with: m.range(at: 1)))
		}

		return (val(for: "Red") ?? 1, val(for: "Green") ?? 1, val(for: "Blue") ?? 1)
	}

	private static func extractProjectRootID(from content: String) -> String? {
		let pattern = #"<scenenode[^>]*\sid="(\d+)"[^>]*factoryID="13""#
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }
		return (content as NSString).substring(with: match.range(at: 1))
	}

	private static func findParentScenenodeID(for objectID: String, in content: String) -> String? {
		let behaviorPattern = "<behavior[^>]*\\sid=\"\(objectID)\""
		guard let regex = try? NSRegularExpression(pattern: behaviorPattern),
			let match = regex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }
		let beforeBehavior = (content as NSString).substring(to: match.range.location)
		let scenenodePattern = "<scenenode[^>]*\\sid=\"(\\d+)\""
		guard let snRegex = try? NSRegularExpression(pattern: scenenodePattern) else { return nil }
		let matches = snRegex.matches(
			in: beforeBehavior, range: NSRange(beforeBehavior.startIndex..., in: beforeBehavior))
		return matches.last.map { (beforeBehavior as NSString).substring(with: $0.range(at: 1)) }
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

	private static func extractTextOzml(from content: String) -> TextOzmlInfo? {
		// Find the layer ID
		let layerPattern = #"<layer[^>]*\sid="(\d+)""#
		guard let layerRegex = try? NSRegularExpression(pattern: layerPattern),
			let layerMatch = layerRegex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }
		let layerID = (content as NSString).substring(with: layerMatch.range(at: 1))

		// Find scenenodes containing <text> tags, prefer non-"copy" names
		let snPattern = #"<scenenode\s+name="([^"]+)"\s+id="(\d+)"\s+factoryID="\d+""#
		guard let snRegex = try? NSRegularExpression(pattern: snPattern) else { return nil }
		let snMatches = snRegex.matches(
			in: content, range: NSRange(content.startIndex..., in: content))

		// Filter to scenenodes that contain a <text> tag before the next <scenenode>
		let textScenenodes = snMatches.filter { match in
			let matchEnd = match.range.location + match.range.length
			let searchStart = content.index(content.startIndex, offsetBy: matchEnd)
			let lookahead = String(content[searchStart...].prefix(5000))
			guard let textPos = lookahead.range(of: "<text>") else { return false }
			if let nextScenenode = lookahead.range(of: "<scenenode") {
				return textPos.lowerBound < nextScenenode.lowerBound
			}
			return true
		}
		guard !textScenenodes.isEmpty else { return nil }

		let bestMatch =
			textScenenodes.first(where: {
				let name = (content as NSString).substring(with: $0.range(at: 1))
				return !name.lowercased().contains("copy")
			}) ?? textScenenodes.last!

		let scenenodeID = (content as NSString).substring(with: bestMatch.range(at: 2))

		let tagSearchStart = content.index(
			content.startIndex, offsetBy: bestMatch.range.location)
		guard let tagEnd = content.range(of: ">", range: tagSearchStart..<content.endIndex)
		else { return nil }
		let tagStart = tagSearchStart

		var depth = 1
		var pos = tagEnd.upperBound
		var closeEnd: String.Index?
		while depth > 0 && pos < content.endIndex {
			let remaining = pos..<content.endIndex
			let openRange = content.range(of: "<scenenode", range: remaining)
			let closeRange = content.range(of: "</scenenode>", range: remaining)
			guard let cr = closeRange else { break }
			if let or = openRange, or.lowerBound < cr.lowerBound {
				depth += 1
				pos = or.upperBound
			} else {
				depth -= 1
				if depth == 0 { closeEnd = cr.upperBound }
				pos = cr.upperBound
			}
		}
		guard let end = closeEnd else { return nil }
		let fullScenenode = String(content[tagStart..<end])

		// Extract default text
		var defaultText = "Title"
		if let tStart = fullScenenode.range(of: "<text>"),
			let tEnd = fullScenenode.range(of: "</text>")
		{
			defaultText = String(fullScenenode[tStart.upperBound..<tEnd.lowerBound])
		}

		// Extract style ID (for face color channel keypaths)
		var styleID: String?
		let stylePattern = #"<style[^>]*\sid="(\d+)""#
		if let styleRegex = try? NSRegularExpression(pattern: stylePattern),
			let styleMatch = styleRegex.firstMatch(
				in: fullScenenode, range: NSRange(fullScenenode.startIndex..., in: fullScenenode))
		{
			styleID = (fullScenenode as NSString).substring(with: styleMatch.range(at: 1))
		}

		// Extract ALL factory definitions
		var factories = ""
		var searchStart = content.startIndex
		while let fStart = content.range(of: "<factory ", range: searchStart..<content.endIndex),
			let fEnd = content.range(
				of: "</factory>", range: fStart.lowerBound..<content.endIndex)
		{
			factories += String(content[fStart.lowerBound..<fEnd.upperBound]) + "\n\n"
			searchStart = fEnd.upperBound
		}

		let ozml =
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE ozxmlscene>\n<ozml version=\"5.14\">\n\n"
			+ factories + "\n" + fullScenenode + "\n</ozml>\n"

		let key = "9999/\(layerID)/\(scenenodeID)"
		return TextOzmlInfo(key: key, ozml: ozml, defaultText: defaultText, styleID: styleID)
	}
}
