/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension PublishedParameter {

	/// The full effect-value key for a param whose object is a text `<style>`:
	/// `9999/<every enclosing layer+scenenode>/5/<styleID>/<channelPath>`. nil when
	/// the object isn't a style. Verified against an FCPXML export of a drop-shadow
	/// override (the `/5/` links the scenenode to its style).
	static func extractStyleKey(
		objectID: String, channelPath: String, in content: String
	) -> String? {
		let stylePattern = "<style\\b[^>]*\\sid=\"\(objectID)\""
		guard let rx = try? NSRegularExpression(pattern: stylePattern),
			rx.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
		else { return nil }
		let ancestors = ancestorChain(for: objectID, in: content)
		guard !ancestors.isEmpty else { return nil }
		return "9999/" + ancestors.joined(separator: "/") + "/5/" + objectID + "/" + channelPath
	}

	/// The enclosing `<layer>` / `<scenenode>` ids for an object, outermost first,
	/// via an open/close-tag stack scan up to the object's own tag.
	private static func ancestorChain(for objectID: String, in content: String) -> [String] {
		guard let idRange = content.range(of: "id=\"\(objectID)\"") else { return [] }
		let tagStart = content[..<idRange.lowerBound].lastIndex(of: "<") ?? idRange.lowerBound
		let region = String(content[..<tagStart])

		let pattern = #"<(layer|scenenode)\b([^>]*)>|</(layer|scenenode)>"#
		guard let rx = try? NSRegularExpression(pattern: pattern),
			let idRx = try? NSRegularExpression(pattern: #"\sid="(\d+)""#)
		else { return [] }

		let ns = region as NSString
		var stack: [String] = []
		rx.enumerateMatches(in: region, range: NSRange(location: 0, length: ns.length)) {
			match, _, _ in
			guard let match else { return }
			if match.range(at: 1).location != NSNotFound {
				let attrs = ns.substring(with: match.range(at: 2))
				if attrs.trimmingCharacters(in: .whitespaces).hasSuffix("/") { return }
				if let im = idRx.firstMatch(
					in: attrs, range: NSRange(attrs.startIndex..., in: attrs))
				{
					stack.append((attrs as NSString).substring(with: im.range(at: 1)))
				} else {
					stack.append("?")
				}
			} else if !stack.isEmpty {
				stack.removeLast()
			}
		}
		return stack
	}

	static func extractProjectRootID(from content: String) -> String? {
		let pattern = #"<scenenode[^>]*\sid="(\d+)"[^>]*factoryID="13""#
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }
		return (content as NSString).substring(with: match.range(at: 1))
	}

	static func findParentScenenodeID(for objectID: String, in content: String) -> String? {
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

	static func findContainingLayerID(for objectID: String, in content: String) -> String? {
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

	static func extractTextOzml(from content: String) -> TextOzmlInfo? {
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

		// Filter to scenenodes that contain a <text> tag before the next <scenenode>.
		// Bound the search by the next <scenenode>, not a fixed window: a text layer
		// buried under a large parameter block can sit many KB past its scenenode tag
		// (well beyond any arbitrary lookahead), and missing it drops text overrides.
		let textScenenodes = snMatches.filter { match in
			let matchEnd = match.range.location + match.range.length
			let searchStart = content.index(content.startIndex, offsetBy: matchEnd)
			let remainder = content[searchStart...]
			let region =
				remainder.range(of: "<scenenode").map { remainder[..<$0.lowerBound] }
				?? remainder[...]
			return region.range(of: "<text>") != nil
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

		// The key must trace the scenenode's FULL enclosing layer/scenenode ancestry, not
		// just its outermost layer. A deeply nested scenenode (character-animation
		// templates) sits many levels down; keying it at `9999/<firstLayer>/<scenenode>`
		// points at the wrong node, so FCP silently ignores the whole injected scene (text,
		// size, colour) and renders the template defaults. Falls back to the flat form when
		// no ancestry is found (shallow titles, where the two are identical anyway).
		let ancestors = ancestorChain(for: scenenodeID, in: content)
		let pathToScenenode =
			ancestors.isEmpty
			? "\(layerID)/\(scenenodeID)"
			: ancestors.joined(separator: "/") + "/" + scenenodeID
		let key = "9999/\(pathToScenenode)"

		// Synthesize the text style's font-size key + flags straight from the style (not
		// from a published "Size" param), so the caption Text Size drives it for any
		// template with a text style, published or not.
		let sizeKey = styleID.flatMap {
			extractStyleKey(objectID: $0, channelPath: "3", in: content)
		}
		let sizeFlags = styleID.flatMap {
			extractFlags(objectID: $0, channelPath: "3", in: content)
		}
		return TextOzmlInfo(
			key: key, ozml: ozml, defaultText: defaultText, styleID: styleID,
			sizeKey: sizeKey, sizeFlags: sizeFlags)
	}
}
