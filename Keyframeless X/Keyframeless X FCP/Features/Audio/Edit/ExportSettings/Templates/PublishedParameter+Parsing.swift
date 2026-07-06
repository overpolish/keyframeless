/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension PublishedParameter {

	/// Walk the channel-path ids from the object node to the target `<parameter>`,
	/// returning the index at its opening tag. Shared by every child-value extractor.
	static func resolveNodeStart(
		objectID: String, channelPath: String, in content: String
	) -> String.Index? {
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
		return searchStart
	}

	/// The text of a `<parameter>` element starting at `start`, up to its matching
	/// `</parameter>` (handling self-closing children and nesting). Bounds a child search
	/// to the node's OWN element so it can't bleed into a sibling filter's params - a
	/// fixed-size window would, e.g. reading an outline's absent channels from the next
	/// filter's colour. Returns the open tag alone for a self-closing node.
	static func elementText(from start: String.Index, in content: String) -> String? {
		guard let firstGt = content.range(of: ">", range: start..<content.endIndex)
		else { return nil }
		if content[start..<firstGt.upperBound].hasSuffix("/>") {
			return String(content[start..<firstGt.upperBound])
		}
		var depth = 1
		var pos = firstGt.upperBound
		while depth > 0, pos < content.endIndex {
			let open = content.range(of: "<parameter", range: pos..<content.endIndex)
			guard let close = content.range(of: "</parameter>", range: pos..<content.endIndex)
			else { return nil }
			if let open, open.lowerBound < close.lowerBound {
				guard let gt = content.range(of: ">", range: open.lowerBound..<content.endIndex)
				else { return nil }
				if !content[open.lowerBound..<gt.upperBound].hasSuffix("/>") { depth += 1 }
				pos = gt.upperBound
			} else {
				depth -= 1
				if depth == 0 { return String(content[start..<close.upperBound]) }
				pos = close.upperBound
			}
		}
		return nil
	}

	/// The `value=` of a `name="…"` sub-parameter within a resolved node's lookahead.
	static func childDouble(_ name: String, in lookahead: String) -> Double? {
		let p = "name=\"\(name)\"[^>]*value=\"([^\"]+)\""
		guard let rx = try? NSRegularExpression(pattern: p),
			let m = rx.firstMatch(
				in: lookahead, range: NSRange(lookahead.startIndex..., in: lookahead))
		else { return nil }
		return Double((lookahead as NSString).substring(with: m.range(at: 1)))
	}

	static func extractFontDefault(
		objectID: String, channelPath: String, in content: String
	) -> String? {
		guard
			let searchStart = resolveNodeStart(
				objectID: objectID, channelPath: channelPath, in: content)
		else { return nil }

		let lookahead = String(content[searchStart...].prefix(500))
		let fontPattern = "<font>([^<]+)</font>"
		guard let fontRegex = try? NSRegularExpression(pattern: fontPattern),
			let fontMatch = fontRegex.firstMatch(
				in: lookahead, range: NSRange(lookahead.startIndex..., in: lookahead))
		else { return nil }
		return (lookahead as NSString).substring(with: fontMatch.range(at: 1))
	}

	/// Per-channel RGB defaults for a colour param. A channel is `nil` when Motion omitted
	/// it - Motion stores colours sparsely, writing only channels that differ from the
	/// param's per-channel factory default. Callers apply the right base for absent
	/// channels (white for a face colour via `?? 1`, red for an outline); collapsing
	/// absent→1 here would lose that distinction.
	static func extractColorDefaults(
		objectID: String, channelPath: String, in content: String
	) -> (r: Double?, g: Double?, b: Double?)? {
		guard
			let searchStart = resolveNodeStart(
				objectID: objectID, channelPath: channelPath, in: content)
		else { return nil }

		guard let region = elementText(from: searchStart, in: content),
			region.contains("name=\"Red\"") || region.contains("name=\"Green\"")
				|| region.contains("name=\"Blue\"")
		else { return nil }

		return (
			childDouble("Red", in: region),
			childDouble("Green", in: region),
			childDouble("Blue", in: region)
		)
	}

	/// The X/Y child values of a Position-style param (a `<parameter>` with `X`/`Y`
	/// sub-parameters). nil when the resolved node isn't a 2D point.
	static func extractPoint(
		objectID: String, channelPath: String, in content: String
	) -> (x: Double, y: Double)? {
		guard
			let searchStart = resolveNodeStart(
				objectID: objectID, channelPath: channelPath, in: content)
		else { return nil }

		let lookahead = String(content[searchStart...].prefix(600))
		guard lookahead.contains("name=\"X\"") && lookahead.contains("name=\"Y\"")
		else { return nil }
		guard let x = childDouble("X", in: lookahead), let y = childDouble("Y", in: lookahead)
		else { return nil }
		return (x, y)
	}

	/// A published pop-up (enum) param: options are auto-read from `<entry>` children
	/// on the resolved node. Built-in enums with no inline entries (e.g. Vertical
	/// Alignment) fall back to known values. Returns nil for non-enum params.
	static func extractDropdown(
		objectID: String, channelPath: String, name: String, in content: String
	) -> (options: [DropdownOption], defaultTag: Int?)? {
		guard
			let searchStart = resolveNodeStart(
				objectID: objectID, channelPath: channelPath, in: content)
		else { return nil }

		// searchStart is at the target `<parameter ...>`. Read its opening tag, then
		// its <entry> children up to the closing tag (pop-ups have no nested params).
		guard let tagClose = content.range(of: ">", range: searchStart..<content.endIndex)
		else { return nil }
		let openTag = String(content[searchStart..<tagClose.upperBound])
		let templateTag = attrInt("value", in: openTag)

		var options: [DropdownOption] = []
		if !openTag.hasSuffix("/>") {
			let bodyEnd =
				content.range(of: "</parameter>", range: tagClose.upperBound..<content.endIndex)?
				.lowerBound ?? content.endIndex
			let body = String(content[tagClose.upperBound..<bodyEnd])
			let entryPattern = #"<entry\s+name="([^"]*)"\s+tag="([^"]+)""#
			if let rx = try? NSRegularExpression(pattern: entryPattern) {
				for m in rx.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
					let ename = (body as NSString).substring(with: m.range(at: 1))
					guard !ename.trimmingCharacters(in: .whitespaces).isEmpty,
						let etag = Int((body as NSString).substring(with: m.range(at: 2)))
					else { continue }
					options.append(DropdownOption(name: ename, tag: etag))
				}
			}
		}

		// A single (or zero) real option isn't a menu - e.g. blank separator params
		// whose only <entry> is whitespace. Fall through to the known-enum tables.
		if options.count >= 2 {
			return (options, templateTag)
		}

		// Built-in / behavior enums whose options live in Motion's compiled factory,
		// not the .moti. `defaultTag` overrides the template value where a
		// caption-friendly default differs (e.g. Vertical Alignment → Center).
		if let known = knownEnum(channelPath: channelPath, name: name) {
			return (known.options, known.defaultTag ?? templateTag)
		}
		return nil
	}

	/// Option lists for pop-ups that don't inline their `<entry>` children. Keyed by
	/// CHANNEL PATH (the behavior/object param id), which survives a creator renaming
	/// the published param - the display name does not. Params whose channel path
	/// carries an instance id (horizontal Alignment) fall back to a name key.
	///
	/// Tags are assumed sequential 0-based, pending verification against Motion.
	private static func knownEnum(channelPath: String, name: String)
		-> (options: [DropdownOption], defaultTag: Int?)?
	{
		if let byChannel = enumsByChannel[channelPath] { return byChannel }
		return enumsByName[name.trimmingCharacters(in: .whitespaces)]
	}

	private static func seq(_ names: [String]) -> [DropdownOption] {
		names.enumerated().map { DropdownOption(name: $0.element, tag: $0.offset) }
	}

	private static let enumsByChannel: [String: (options: [DropdownOption], defaultTag: Int?)] = [
		// Text object (Vertical Alignment defaults to Center for captions).
		"2/373/2": (seq(["Top", "Center", "Bottom"]), 1),
		// "Animate Format" behavior params (object channel 201/…).
		"201/202": (seq(["To", "From", "Through", "Through Inverted", "From Keyframes"]), nil),
		"201/203": (
			seq(["Character", "Character (no spaces)", "Word", "Line", "All", "Custom"]), nil
		),
		"201/205": (
			seq(["Forwards", "Backwards", "Center to Ends", "Ends to Center", "Random"]), nil
		),
		"201/208": (
			seq([
				"Constant", "Ease In", "Ease Out", "Ease Both", "Accelerate", "Decelerate",
				"Custom",
			]),
			nil
		),
		"201/211": (seq(["Once Per Loop", "Over Entire Duration", "Per Object"]), nil),
	]

	private static let enumsByName: [String: (options: [DropdownOption], defaultTag: Int?)] = [
		"Alignment": (
			seq([
				"Left", "Center", "Right", "Left Justified", "Center Justified",
				"Right Justified", "Justified",
			]), nil
		)
	]

	static func attrInt(_ attr: String, in tag: String) -> Int? {
		guard let r = tag.range(of: "\(attr)=\"") else { return nil }
		let after = tag[r.upperBound...]
		guard let end = after.firstIndex(of: "\"") else { return nil }
		return Int(after[..<end])
	}

	static func attrDouble(_ attr: String, in tag: String) -> Double? {
		guard let r = tag.range(of: "\(attr)=\"") else { return nil }
		let after = tag[r.upperBound...]
		guard let end = after.firstIndex(of: "\"") else { return nil }
		return Double(after[..<end])
	}

	static func attrString(_ attr: String, in tag: String) -> String? {
		guard let r = tag.range(of: "\(attr)=\"") else { return nil }
		let after = tag[r.upperBound...]
		guard let end = after.firstIndex(of: "\"") else { return nil }
		return String(after[..<end])
	}

	/// The opening tag of the parameter a published `object`+`channel` resolves to,
	/// by walking the channel-path ids from the object node.
	static func resolveOpenTag(
		objectID: String, channelPath: String, in content: String
	) -> String? {
		guard
			let searchStart = resolveNodeStart(
				objectID: objectID, channelPath: channelPath, in: content)
		else { return nil }
		guard let tagClose = content.range(of: ">", range: searchStart..<content.endIndex)
		else { return nil }
		return String(content[searchStart..<tagClose.upperBound])
	}

	/// The resolved node's numeric `value=`, used to seed a `.slider` field so it
	/// opens on the template's real value rather than 0.
	static func extractNumber(
		objectID: String, channelPath: String, in content: String
	) -> Double? {
		guard let tag = resolveOpenTag(objectID: objectID, channelPath: channelPath, in: content)
		else { return nil }
		return attrDouble("value", in: tag)
	}

	/// The resolved node's own `flags`, mirrored onto our override so FCP honors it the
	/// same way its inspector would (a generic flag value is ignored by rigged params).
	static func extractFlags(
		objectID: String, channelPath: String, in content: String
	) -> Int? {
		guard let tag = resolveOpenTag(objectID: objectID, channelPath: channelPath, in: content)
		else { return nil }
		return attrInt("flags", in: tag)
	}

	/// If the param targets a filter GROUP (a `<parameter>` with `flags` but no
	/// `value` - its on/off is the `0x800` enable bit), the group's ozml name +
	/// base flags. nil for ordinary value toggles.
	static func extractFilterEnable(
		objectID: String, channelPath: String, in content: String
	) -> (name: String, flags: Int)? {
		guard let tag = resolveOpenTag(objectID: objectID, channelPath: channelPath, in: content),
			!tag.contains("value=\""),
			let flags = attrInt("flags", in: tag),
			let name = attrString("name", in: tag)
		else { return nil }
		return (name, flags)
	}
}
