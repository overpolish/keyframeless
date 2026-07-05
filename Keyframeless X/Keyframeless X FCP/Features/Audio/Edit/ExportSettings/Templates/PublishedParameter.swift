/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
	/// Menu options auto-detected from the template, for `.dropdown` params.
	var options: [DropdownOption]?
	/// The param's own `value=` at parse time, used as the dropdown default.
	var defaultTag: Int?
	/// The param's numeric `value=` at parse time, seeds the `.slider` field.
	var defaultNumber: Double?
	/// For params living inside the text `<style>`, the exact effect-value key FCP
	/// expects: `9999/<every enclosing layer+scenenode>/5/<styleID>/<channel>`. The
	/// generic `effectValueKey` uses only one parent layer and is silently ignored
	/// for these (verified against an FCPXML export). nil for non-style params.
	var styleKey: String?
	/// For a toggle whose target is a filter GROUP (e.g. "Drop Shadow On/Off"), the
	/// group's ozml `name` and base `flags`. Such a group has no value curve — FCP
	/// enables it by an override at the group key carrying `flags & ~0x8000` (the
	/// disable bit cleared); absence of that override means off. nil for value toggles.
	var filterEnableName: String?
	var filterEnableFlags: Int?
	/// The X/Y child values of a Position-style param, seeding the `.point` fields.
	var defaultX: Double?
	var defaultY: Double?

	/// FCP displays a point at `native × this` (calibrated from FCP: our 100 → 4.6,
	/// 10 → 0.5). So the field works in FCP units: seed = native × scale, emit =
	/// field ÷ scale. Refine if a clean native↔FCP capture becomes available.
	static let pointDisplayScale = 0.046

	struct DropdownOption: Codable, Equatable, Hashable, Identifiable {
		var id: Int { tag }
		let name: String
		let tag: Int
	}

	enum ParamKind: String, Codable, Equatable {
		case off
		case color
		case slider
		case toggle
		case animation
		case font
		case dropdown
		case rotation
		case point

		init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			switch raw {
			case "fontProject", "fontCustom": self = .font
			default: self = ParamKind(rawValue: raw) ?? .off
			}
		}
	}

	var isFont: Bool { kind == .font }
	var isDropdown: Bool { kind == .dropdown }
	var isToggleable: Bool {
		kind == .color || kind == .slider || kind == .toggle || kind == .dropdown
			|| kind == .rotation || kind == .point
	}

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
			let point =
				(isFont || rgb != nil)
				? nil
				: extractPoint(objectID: objectID, channelPath: channelPath, in: content)
			let dropdown =
				(isFont || rgb != nil || point != nil)
				? nil
				: extractDropdown(
					objectID: objectID, channelPath: channelPath, name: name, in: content)
			let number =
				(isFont || rgb != nil || point != nil || dropdown != nil)
				? nil
				: extractNumber(objectID: objectID, channelPath: channelPath, in: content)
			let layerID = findContainingLayerID(for: objectID, in: content)
			let parentScenenode = findParentScenenodeID(for: objectID, in: content)
			let styleKey = extractStyleKey(
				objectID: objectID, channelPath: channelPath, in: content)
			let filterEnable = extractFilterEnable(
				objectID: objectID, channelPath: channelPath, in: content)
			let kind: ParamKind =
				point != nil ? .point : (dropdown != nil ? .dropdown : .off)
			customParams.append(
				PublishedParameter(
					name: name, objectID: objectID, channel: channel,
					kind: kind,
					isProjectRoot: objectID == projectRootID,
					parentLayerID: layerID, parentScenenodeID: parentScenenode,
					defaultR: rgb?.r, defaultG: rgb?.g, defaultB: rgb?.b,
					defaultFont: fontDefault,
					options: dropdown?.options, defaultTag: dropdown?.defaultTag,
					defaultNumber: number, styleKey: styleKey,
					filterEnableName: filterEnable?.name,
					filterEnableFlags: filterEnable?.flags,
					defaultX: point?.x, defaultY: point?.y))
		}

		let textOzml = extractTextOzml(from: content)
		return ParseResult(
			customParams: customParams, hasPerWordAnimation: hasPerWord, textOzml: textOzml)
	}
}
