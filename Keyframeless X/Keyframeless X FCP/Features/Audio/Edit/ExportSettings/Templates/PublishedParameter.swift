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
	/// group's ozml `name` and base `flags`. Such a group has no value curve - FCP
	/// enables it by an override at the group key carrying `flags & ~0x8000` (the
	/// disable bit cleared); absence of that override means off. nil for value toggles.
	var filterEnableName: String?
	var filterEnableFlags: Int?
	/// The X/Y child values of a Position-style param, seeding the `.point` fields.
	var defaultX: Double?
	var defaultY: Double?
	/// The target param's own `flags` in the moti. FCP's own inspector overrides carry
	/// these (e.g. font Size sets bit 0x1000000); our generic override flags omit them,
	/// which a deeply-rigged param silently ignores. Emit the real flags so the override
	/// is honored. nil when the node has no `flags` attribute.
	var nativeFlags: Int?

	/// Backing store for `isTextSize`. Optional so params persisted before this field
	/// existed still decode - synthesized `Codable` throws on a missing NON-optional key
	/// (it ignores default values), which would wipe every saved template's settings.
	var isTextSizeStored: Bool?

	/// True for the text-style font-size param (channel 3 on the injected style). It's
	/// the same value as the caption's Text Size field, so it's hidden from the custom-
	/// control picker and emitted directly rather than offered as a generic control.
	var isTextSize: Bool {
		get { isTextSizeStored ?? false }
		set { isTextSizeStored = newValue }
	}

	/// Flags to stamp on a numeric override. FCP's inspector writes the param's own flags
	/// OR'd with the `0x100000000` "rigged override" bit, which a replicated / deeply
	/// nested param (character-animation templates) requires to accept the value. Shallow
	/// titles tolerate its absence, so setting it unconditionally is safe. Falls back to
	/// the generic value only when the node carried no `flags` at all.
	var overrideFlags: Int {
		guard let f = nativeFlags else { return 8_589_934_608 }
		return f | 0x1_0000_0000
	}

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
		case percent

		init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			switch raw {
			case "fontProject", "fontCustom": self = .font
			default: self = ParamKind(rawValue: raw) ?? .off
			}
		}
	}

	/// Motion text-style face-layer channel ids. These are FIXED factory ids (part of
	/// Motion's text-style factory, identical across every template), so filter detection
	/// keys off them, NEVER the creator-renamable published name.
	enum TextFilter {
		static let dropShadow = "21"
		static let outline = "30"
		// Drop Shadow sub-params
		static let shadowColor = "23"
		static let shadowOpacity = "26"
		static let shadowDistance = "27"
		static let shadowAngle = "29"
		static let shadowBlur = "75"
		// Outline sub-params
		static let outlineColor = "32"
		static let outlineWidth = "36"
	}

	var isFont: Bool { kind == .font }
	var isDropdown: Bool { kind == .dropdown }
	var isToggleable: Bool {
		kind == .color || kind == .slider || kind == .toggle || kind == .dropdown
			|| kind == .rotation || kind == .point || kind == .percent
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
		/// The text style's font-size (channel 3) effect-value key + its moti flags,
		/// synthesized directly from the style so the caption Text Size can drive it even
		/// when the template doesn't publish "Size". nil when there's no text style.
		let sizeKey: String?
		let sizeFlags: Int?
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
		let textOzml = extractTextOzml(from: content)

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
			let nativeFlags = extractFlags(
				objectID: objectID, channelPath: channelPath, in: content)
			let isTextSize = objectID == textOzml?.styleID && channelPath == "3"
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
					defaultX: point?.x, defaultY: point?.y,
					nativeFlags: nativeFlags, isTextSizeStored: isTextSize))
		}

		// Face-layer filters store colours/numerics SPARSELY - Motion omits any channel
		// already at its per-filter factory default. Fill the omitted ones so the control's
		// shown default and the emitted attr agree. Keyed by FIXED Motion channel ids (see
		// TextFilter), never the renamable name. Per filter: colour base + factory numerics.
		let filterSpecs:
			[(
				group: String, colorSub: String, base: (Double, Double, Double),
				numbers: [(sub: String, value: Double)]
			)] = [
				(
					TextFilter.dropShadow, TextFilter.shadowColor, (0, 0, 0),
					[
						(TextFilter.shadowOpacity, 75), (TextFilter.shadowDistance, 5),
						(TextFilter.shadowAngle, 315), (TextFilter.shadowBlur, 0),
					]
				),
				(TextFilter.outline, TextFilter.outlineColor, (1, 0, 0), []),
			]
		for enable in customParams where enable.filterEnableFlags != nil {
			guard let spec = filterSpecs.first(where: { $0.group == enable.channelParamID })
			else { continue }
			let colorChannel = enable.channelPath + "/" + spec.colorSub
			for i in customParams.indices where customParams[i].channelPath == colorChannel {
				customParams[i].defaultR = customParams[i].defaultR ?? spec.base.0
				customParams[i].defaultG = customParams[i].defaultG ?? spec.base.1
				customParams[i].defaultB = customParams[i].defaultB ?? spec.base.2
			}
			for (sub, value) in spec.numbers {
				let ch = enable.channelPath + "/" + sub
				for i in customParams.indices
				where customParams[i].channelPath == ch && customParams[i].defaultNumber == nil {
					customParams[i].defaultNumber = value
				}
			}
		}

		// A Blur is stored as a 2D X/Y point in Motion, but we expose it as a single value
		// (uniform blur, no elliptical support) and map it back to X=Y on emit. Take X as
		// the value and drop the point so it parses as a plain numeric, not a Point control.
		let blurSuffix = "/" + TextFilter.dropShadow + "/" + TextFilter.shadowBlur
		for i in customParams.indices
		where customParams[i].channelPath.hasSuffix(blurSuffix)
			|| customParams[i].channelPath == "\(TextFilter.dropShadow)/\(TextFilter.shadowBlur)"
		{
			if let x = customParams[i].defaultX {
				customParams[i].defaultNumber = x
				customParams[i].defaultX = nil
				customParams[i].defaultY = nil
				if customParams[i].kind == .point { customParams[i].kind = .off }
			}
		}

		return ParseResult(
			customParams: customParams, hasPerWordAnimation: hasPerWord, textOzml: textOzml)
	}
}
