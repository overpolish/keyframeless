/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Foundation

enum FCPNativePasteboardBuilder {

	struct TitleEntry {
		let displayName: String
		let text: String
		let startTime: Double
		let duration: Double
		var wordStarts: [Double] = []
	}

	struct Style {
		let fontFamily: String
		let fontPostScript: String
		let fontSize: Int
		let colorR: Double
		let colorG: Double
		let colorB: Double
		let colorA: Double
		let yPositionPercent: Double
	}

	struct TemplateInfo {
		let effectID: String
		let fileURL: String
		let name: String
		var wordsInKeyPath: String?
		var wordsInParamName: String?
		var perWordStartsAtZero: Bool = false
		var textOzmlKey: String?
		var textOzml: String?
		var textOzmlDefaultText: String?
		var textOzmlStyleID: String?
	}

	struct EffectValueEntry {
		let key: String
		let data: Data
	}

	// Template object indices (from fcp_position_paste.plist captured with Y=200):
	// [5]  Container, [6] UUID, [8] range
	// [10] Gap, [11] UUID, [12] "Gap", [13] gap range
	// [14] Gap anchoredItems set
	// [15] Title (FFAnchoredGeneratorComponent), [16] UUID, [17] name, [18] anchorPair, [19] range
	// [20] EffectStack, [21] UUID
	// [22] CustomEffect (FFMotionEffect), [23] URL dict, [24] URL string, [26] UUID, [27] effectID, [28] effectType
	// [31] IntrinsicEffects array
	// [32] FFHeColorEffect, [33] UUID, [34] effectID, [35] effectType, [36] name, [37] effects array
	// [38] NSMutableArray class
	// [40] FFIntrinsicColorConformEffect, [41] UUID
	// [45] FFHeConformEffect, [46] UUID, [48] channelData
	// [51] FFHeXForm3DEffect, [52] UUID, [54] channelData (Y position)
	// [59] roleUID
	// [61] NSMutableSet class
	// [62] FFAnchoredGapGeneratorComponent class
	// [66] "0/1" (unclippedStart)
	// [67] videoProps dict
	// [83] AudioLayoutMap, [84] UUID
	// [87] FFAnchoredCollection class

	struct StorylineGroup {
		let titles: [TitleEntry]
		let clipStartTime: Double
	}

	static func build(
		storylines: [[TitleEntry]],
		clipStartTimes: [Double]? = nil,
		style: Style = Style(
			fontFamily: "Helvetica", fontPostScript: "Helvetica",
			fontSize: 63,
			colorR: 1, colorG: 1, colorB: 1, colorA: 1,
			yPositionPercent: 50),
		frameDuration: String = "1001/24000s",
		mediaStartTime: Double = 3600.0,
		templateInfo: TemplateInfo? = nil,
		publishedParams: [EffectValueEntry] = []
	) -> Data? {
		let allTitles = storylines.flatMap { $0 }
		guard !allTitles.isEmpty else { return nil }
		let frameRate = parseFrameDuration(frameDuration)

		guard
			let templateURL = Bundle(for: FCPDragSourceView.self)
				.url(forResource: "BasicTitleTemplate", withExtension: "plist"),
			let templateData = try? Data(contentsOf: templateURL),
			var plist = try? PropertyListSerialization.propertyList(
				from: templateData, options: .mutableContainersAndLeaves, format: nil
			) as? [String: Any],
			let objData = plist["ffpasteboardobject"] as? Data,
			var archive = try? PropertyListSerialization.propertyList(
				from: objData, options: .mutableContainersAndLeaves, format: nil
			) as? [String: Any],
			var objects = archive["$objects"] as? [Any]
		else { return nil }

		// Assign Captions role (subrole UUID from template's embedded roles data)
		objects[59] = "VaUwsjFSHS5Cpf3PuyPV0Cw"

		let isBasicTitle = templateInfo == nil

		var baseOzml: String?
		if isBasicTitle {
			guard
				let ozmlURL = Bundle(for: FCPDragSourceView.self)
					.url(forResource: "BasicTitleOzml", withExtension: "xml"),
				let ozml = try? String(contentsOf: ozmlURL, encoding: .utf8)
			else { return nil }
			baseOzml = ozml
		}

		// Swap template URL/effectID for custom templates
		if let info = templateInfo {
			objects[17] = info.name
			objects[24] = info.fileURL
			objects[27] = info.effectID
		}

		let yPercent = style.yPositionPercent - 50.0
		patchTransformY(in: &objects, at: 54, yPercent: yPercent)

		let mevClassIdx = objects.count
		objects.append(
			[
				"$classname": "FFMotionEffectValue",
				"$classes": [
					"FFMotionEffectValue", "FFBaseDSObject", "FFModelObject", "DSObject",
					"NSObject",
				],
			] as [String: Any])

		// Remove anchor properties from template title (storyline will own them)
		if var t = objects[15] as? [String: Any] {
			t.removeValue(forKey: "anchoredLane")
			t.removeValue(forKey: "anchorPair")
			objects[15] = t
		}

		var usedTemplateTitle = false
		var storylineUIDs: [Any] = []
		var globalEarliestFrame = Int.max
		var globalLatestFrame = 0

		for (slIndex, titles) in storylines.enumerated() {
			guard !titles.isEmpty else { continue }
			let sorted = titles.sorted { $0.startTime < $1.startTime }

			// Clip anchor: if provided, storyline anchors to the clip's start
			// Titles are positioned relative to the clip start
			let clipStart = clipStartTimes?[slIndex] ?? sorted[0].startTime
			let clipStartFrames = frames(seconds: clipStart, frameRate: frameRate)

			var items: [Any] = []
			var cursorFrames = clipStartFrames

			for (i, title) in sorted.enumerated() {
				let titleStartFrames = frames(seconds: title.startTime, frameRate: frameRate)
				let titleEndFrames: Int
				if i + 1 < sorted.count,
					sorted[i + 1].startTime - (title.startTime + title.duration) < 0.001
				{
					titleEndFrames = frames(seconds: sorted[i + 1].startTime, frameRate: frameRate)
				} else {
					titleEndFrames = frames(
						seconds: title.startTime + title.duration, frameRate: frameRate)
				}

				let gapFrames = titleStartFrames - cursorFrames
				if gapFrames > 0 {
					items.append(
						makeGap(
							into: &objects, durationFrames: gapFrames,
							mediaStartTime: mediaStartTime, frameRate: frameRate))
				}

				let titleDurFrames = titleEndFrames - titleStartFrames
				let range = rationalRange(
					startSeconds: mediaStartTime, durationFrames: titleDurFrames,
					frameRate: frameRate)

				let titleEVs = buildTitleEffectValues(
					title: title, style: style, baseOzml: baseOzml,
					publishedParams: publishedParams, templateInfo: templateInfo,
					mediaStartTime: mediaStartTime, frameRate: frameRate)

				if !usedTemplateTitle {
					usedTemplateTitle = true
					if templateInfo == nil { objects[17] = title.displayName }
					objects[19] = range
					regenerateUUIDs(in: &objects, at: cloneIndices)
					addEffectValues(
						into: &objects, mevClassIdx: mevClassIdx, customEffectIdx: 22,
						entries: titleEVs)
					items.append(makeUID(15))
				} else {
					items.append(
						cloneTitle(
							into: &objects, displayName: title.displayName,
							range: range, style: style,
							mevClassIdx: mevClassIdx, entries: titleEVs,
							isBasicTitle: isBasicTitle))
				}

				cursorFrames = titleEndFrames
			}

			globalEarliestFrame = min(globalEarliestFrame, clipStartFrames)
			globalLatestFrame = max(globalLatestFrame, cursorFrames)

			// anchorPair second value = absolute media time where storyline anchors
			let anchorMediaTime = mediaStartTime + (clipStartTimes?[slIndex] ?? sorted[0].startTime)
			let lane = slIndex + 1
			storylineUIDs.append(
				makeStoryline(
					into: &objects, items: items, lane: lane,
					anchorMediaTime: anchorMediaTime, frameRate: frameRate))
		}

		// Set gap anchoredItems to all storylines
		objects[14] =
			[
				"$class": makeUID(61),
				"NS.objects": storylineUIDs,
			] as [String: Any]

		// Update gap range to span all titles
		let totalFrames = globalLatestFrame - globalEarliestFrame
		objects[8] = "{(0/1),(\(totalFrames * frameRate.numerator)/\(frameRate.denominator))}"
		objects[13] = rationalRange(
			startSeconds: mediaStartTime, durationFrames: totalFrames, frameRate: frameRate)

		if storylineUIDs.count == 1 {
			// Single storyline: skip container (drag-friendly)
			if var topArr = objects[4] as? [String: Any] {
				topArr["NS.objects"] = storylineUIDs
				objects[4] = topArr
			}
		}
		// Multi storyline: keep container [5] as top-level (paste needs it for anchor pairs)

		regenerateUUIDs(in: &objects, at: [6, 11])

		archive["$objects"] = objects
		guard
			let newObjData = try? PropertyListSerialization.data(
				fromPropertyList: archive, format: .binary, options: 0
			)
		else { return nil }
		plist["ffpasteboardobject"] = newObjData
		return try? PropertyListSerialization.data(
			fromPropertyList: plist, format: .binary, options: 0
		)
	}

	static func buildTitleEffectValues(
		title: TitleEntry,
		style: Style,
		baseOzml: String?,
		publishedParams: [EffectValueEntry],
		templateInfo: TemplateInfo?,
		mediaStartTime: Double,
		frameRate: FrameRate
	) -> [EffectValueEntry] {
		var entries: [EffectValueEntry] = []
		let escaped = title.text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")

		if let baseOzml {
			var ozml = baseOzml
			ozml = ozml.replacingOccurrences(
				of: "<text>Hello World</text>", with: "<text>\(escaped)</text>")
			ozml = ozml.replacingOccurrences(
				of: "<font>Helvetica</font>", with: "<font>\(style.fontPostScript)</font>")
			ozml = ozml.replacingOccurrences(
				of: "default=\"63\" value=\"63\"",
				with: "default=\"\(style.fontSize)\" value=\"\(style.fontSize)\"")
			entries.append(
				EffectValueEntry(
					key: "9999/999166631/999166633", data: ozml.data(using: .utf8)!))
			entries.append(
				contentsOf: OzmlBuilder.colorEntries(
					keyBase: "9999/999166631/999166633/5/999166635/14/16",
					r: style.colorR, g: style.colorG, b: style.colorB))
		} else {
			entries.append(contentsOf: publishedParams)
			if let info = templateInfo,
				let textOzmlKey = info.textOzmlKey,
				let textOzml = info.textOzml,
				let defaultText = info.textOzmlDefaultText
			{
				var patched = textOzml.replacingOccurrences(
					of: "<text>\(defaultText)</text>", with: "<text>\(escaped)</text>")
				patchOzmlAttribute(
					&patched, tag: "<font>", endTag: "</font>",
					replacement: style.fontPostScript)
				patchOzmlAttribute(
					&patched, after: "name=\"Size\" id=\"3\"",
					attribute: "value", replacement: "\(style.fontSize)")
				entries.append(
					EffectValueEntry(
						key: textOzmlKey, data: patched.data(using: .utf8)!))
				if let styleID = info.textOzmlStyleID {
					entries.append(
						contentsOf: OzmlBuilder.colorEntries(
							keyBase: "\(textOzmlKey)/5/\(styleID)/14/16",
							r: style.colorR, g: style.colorG, b: style.colorB))
				}
			}
		}

		if let info = templateInfo,
			let wordsInKey = info.wordsInKeyPath,
			!title.wordStarts.isEmpty
		{
			let wordsInParamID = wordsInKey.split(separator: "/").last.map(String.init) ?? "100"
			entries.append(
				EffectValueEntry(
					key: wordsInKey,
					data: OzmlBuilder.wordsIn(
						paramName: info.wordsInParamName ?? "Words In",
						paramID: wordsInParamID,
						wordStarts: title.wordStarts,
						titleStartTime: title.startTime,
						mediaStartTime: mediaStartTime,
						frameRate: frameRate,
						startsAtZero: info.perWordStartsAtZero)))
		}

		return entries
	}

	private static func patchOzmlAttribute(
		_ ozml: inout String, tag: String, endTag: String, replacement: String
	) {
		if let start = ozml.range(of: tag),
			let end = ozml.range(of: endTag, range: start.upperBound..<ozml.endIndex)
		{
			ozml.replaceSubrange(start.upperBound..<end.lowerBound, with: replacement)
		}
	}

	private static func patchOzmlAttribute(
		_ ozml: inout String, after marker: String, attribute: String, replacement: String
	) {
		if let markerRange = ozml.range(of: marker),
			let attrStart = ozml.range(
				of: "\(attribute)=\"", range: markerRange.upperBound..<ozml.endIndex),
			let attrEnd = ozml.range(of: "\"", range: attrStart.upperBound..<ozml.endIndex)
		{
			ozml.replaceSubrange(attrStart.upperBound..<attrEnd.lowerBound, with: replacement)
		}
	}

	struct FrameRate {
		let numerator: Int
		let denominator: Int
	}
}
