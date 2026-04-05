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
	}

	struct Style {
		let fontFamily: String
		let fontSize: Int
		let colorR: Double
		let colorG: Double
		let colorB: Double
		let colorA: Double
		let yPositionPercent: Double
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

	static func build(
		titles: [TitleEntry],
		style: Style = Style(
			fontFamily: "Helvetica", fontSize: 63,
			colorR: 1, colorG: 1, colorB: 1, colorA: 1,
			yPositionPercent: 50),
		frameDuration: String = "1001/24000s",
		mediaStartTime: Double = 3600.0
	) -> Data? {
		guard !titles.isEmpty else { return nil }
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

		// Load base ozml for text/font/size patching
		guard
			let ozmlURL = Bundle(for: FCPDragSourceView.self)
				.url(forResource: "BasicTitleOzml", withExtension: "xml"),
			let baseOzml = try? String(contentsOf: ozmlURL, encoding: .utf8)
		else { return nil }

		// Patch transform Y position
		let yPercent = style.yPositionPercent - 50.0
		patchTransformY(in: &objects, at: 54, yPercent: yPercent)

		// Add FFMotionEffectValue class definition (not in this template)
		let mevClassIdx = objects.count
		objects.append(
			[
				"$classname": "FFMotionEffectValue",
				"$classes": [
					"FFMotionEffectValue", "FFBaseDSObject", "FFModelObject", "DSObject",
					"NSObject",
				],
			] as [String: Any])

		// Add effectValues for first title
		addEffectValues(
			into: &objects, mevClassIdx: mevClassIdx, customEffectIdx: 22,
			baseOzml: baseOzml, text: titles.sorted(by: { $0.startTime < $1.startTime })[0].text,
			style: style)

		// Build storyline items using absolute frame positions
		let sorted = titles.sorted { $0.startTime < $1.startTime }
		var storylineItems: [Any] = []
		var cursorFrames = frames(seconds: sorted[0].startTime, frameRate: frameRate)

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
				storylineItems.append(
					makeGap(
						into: &objects, durationFrames: gapFrames,
						mediaStartTime: mediaStartTime, frameRate: frameRate))
			}

			let titleDurFrames = titleEndFrames - titleStartFrames
			let range = rationalRange(
				startSeconds: mediaStartTime, durationFrames: titleDurFrames, frameRate: frameRate)

			if i == 0 {
				objects[17] = title.displayName
				objects[19] = range
				regenerateUUIDs(in: &objects, at: cloneIndices)
				storylineItems.append(makeUID(15))
			} else {
				storylineItems.append(
					cloneTitle(
						into: &objects, displayName: title.displayName,
						text: title.text, range: range, style: style,
						baseOzml: baseOzml, mevClassIdx: mevClassIdx))
			}

			cursorFrames = titleEndFrames
		}

		// Remove anchor properties from template title (storyline will own them)
		if var t = objects[15] as? [String: Any] {
			t.removeValue(forKey: "anchoredLane")
			t.removeValue(forKey: "anchorPair")
			objects[15] = t
		}

		if storylineItems.count == 1 {
			// Single title — restore anchor properties
			if var t = objects[15] as? [String: Any] {
				t["anchoredLane"] = 1 as NSNumber
				t["anchorPair"] = makeUID(18)
				objects[15] = t
			}
			objects[14] =
				[
					"$class": makeUID(61),
					"NS.objects": [makeUID(15)],
				] as [String: Any]
			if var topArr = objects[4] as? [String: Any] {
				topArr["NS.objects"] = [makeUID(15)]
				objects[4] = topArr
			}
		} else {
			// Create storyline
			let slContentsIdx = objects.count
			objects.append(
				[
					"$class": makeUID(38),
					"NS.objects": storylineItems,
				] as [String: Any])

			let slIdx = objects.count
			objects.append(
				[
					"$class": makeUID(87),
					"anchorPair": makeUID(18),
					"anchoredLane": 1 as NSNumber,
					"aoFlagsMask": -1 as NSNumber,
					"containedItems": makeUID(slContentsIdx),
					"displayName": makeUID(slIdx + 1),
					"isSpine": true as NSNumber,
					"persistentID": makeUID(slIdx + 2),
					"unclippedStart": makeUID(66),
					"videoProps": makeUID(67),
				] as [String: Any])
			objects.append("Storyline")
			objects.append(UUID().uuidString.uppercased())

			objects[14] =
				[
					"$class": makeUID(61),
					"NS.objects": [makeUID(slIdx)],
				] as [String: Any]

			if var topArr = objects[4] as? [String: Any] {
				topArr["NS.objects"] = [makeUID(slIdx)]
				objects[4] = topArr
			}
		}

		// Update gap range
		let totalFrames = cursorFrames - frames(seconds: sorted[0].startTime, frameRate: frameRate)
		objects[13] = rationalRange(
			startSeconds: mediaStartTime, durationFrames: totalFrames, frameRate: frameRate)

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

	// Per-title objects to clone
	private static let cloneIndices: [Int] = [
		15, 16, 17, 19,
		20, 21,
		22, 23, 26,
		31, 32, 33, 37,
		40, 41,
		45, 46, 48,
		51, 52, 54,
		59, 83, 84,
	]

	private static func makeGap(
		into objects: inout [Any],
		durationFrames: Int,
		mediaStartTime: Double,
		frameRate: FrameRate
	) -> Any {
		let idx = objects.count
		objects.append(
			[
				"$class": makeUID(62),
				"aoFlagsMask": -1 as NSNumber,
				"clippedRange": makeUID(idx + 2),
				"displayName": makeUID(12),
				"hasAudio": 0 as NSNumber,
				"hasVideo": 0 as NSNumber,
				"persistentID": makeUID(idx + 1),
			] as [String: Any])
		objects.append(UUID().uuidString.uppercased())
		objects.append(
			rationalRange(
				startSeconds: mediaStartTime, durationFrames: durationFrames, frameRate: frameRate))
		return makeUID(idx)
	}

	private static func cloneTitle(
		into objects: inout [Any],
		displayName: String,
		text: String,
		range: String,
		style: Style,
		baseOzml: String,
		mevClassIdx: Int
	) -> Any {
		var remap: [Int: Int] = [:]
		let baseIdx = objects.count
		for (offset, origIdx) in cloneIndices.enumerated() {
			remap[origIdx] = baseIdx + offset
		}
		for origIdx in cloneIndices {
			objects.append(deepCopy(objects[origIdx], remap: remap))
		}
		objects[remap[17]!] = displayName
		objects[remap[19]!] = range
		regenerateUUIDs(in: &objects, at: Array(remap.values))

		// Patch transform Y
		patchTransformY(in: &objects, at: remap[54]!, yPercent: style.yPositionPercent - 50.0)

		// Add effectValues for this clone
		addEffectValues(
			into: &objects, mevClassIdx: mevClassIdx, customEffectIdx: remap[22]!,
			baseOzml: baseOzml, text: text, style: style)

		// Remove anchor properties (storyline owns them)
		if var t = objects[remap[15]!] as? [String: Any] {
			t.removeValue(forKey: "anchoredLane")
			t.removeValue(forKey: "anchorPair")
			objects[remap[15]!] = t
		}

		return makeUID(remap[15]!)
	}

	private static func addEffectValues(
		into objects: inout [Any],
		mevClassIdx: Int,
		customEffectIdx: Int,
		baseOzml: String,
		text: String,
		style: Style
	) {
		let escaped =
			text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
		var ozml = baseOzml
		ozml = ozml.replacingOccurrences(
			of: "<text>Hello World</text>", with: "<text>\(escaped)</text>")
		ozml = ozml.replacingOccurrences(
			of: "<font>Helvetica</font>", with: "<font>\(style.fontFamily)</font>")
		ozml = ozml.replacingOccurrences(
			of: "default=\"63\" value=\"63\"",
			with: "default=\"\(style.fontSize)\" value=\"\(style.fontSize)\"")

		var evUIDs: [Any] = []
		evUIDs.append(
			addEffectValue(
				into: &objects, classIdx: mevClassIdx,
				key: "9999/999166631/999166633", data: ozml.data(using: .utf8)!))

		let colorBase = "9999/999166631/999166633/5/999166635/14/16"
		for (name, suffix, paramID, value) in [
			("Red", "/1", 1, style.colorR),
			("Green", "/2", 2, style.colorG),
			("Blue", "/3", 3, style.colorB),
		] as [(String, String, Int, Double)] {
			evUIDs.append(
				addEffectValue(
					into: &objects, classIdx: mevClassIdx,
					key: "\(colorBase)\(suffix)", data: makeColorData(name, paramID, value)))
		}

		let evArrayIdx = objects.count
		objects.append(
			[
				"$class": makeUID(61),
				"NS.objects": evUIDs,
			] as [String: Any])

		if var ce = objects[customEffectIdx] as? [String: Any] {
			ce["effectValues"] = makeUID(evArrayIdx)
			objects[customEffectIdx] = ce
		}
	}

	private static func addEffectValue(
		into objects: inout [Any], classIdx: Int, key: String, data: Data
	) -> Any {
		let idx = objects.count
		objects.append(
			[
				"$class": makeUID(classIdx),
				"data": makeUID(idx + 3),
				"key": makeUID(idx + 2),
				"persistentID": makeUID(idx + 1),
			] as [String: Any])
		objects.append(UUID().uuidString.uppercased())
		objects.append(key)
		objects.append(data)
		return makeUID(idx)
	}

	private static func makeColorData(_ name: String, _ paramID: Int, _ value: Double) -> Data {
		let s =
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE ozxmlscene>\n"
			+ "<ozml version=\"5.14\">\n"
			+ "<factory id=\"1\" uuid=\"fdc1944b229111d7b1c300039389b702\">\n"
			+ "\t<description>Channel</description>\n\t<manufacturer>Apple</manufacturer>\n"
			+ "\t<version>1</version>\n</factory>\n"
			+ "<parameter name=\"\(name)\" id=\"\(paramID)\" factoryID=\"1\">\n"
			+ "\t<flags>8589934608</flags>\n"
			+ "\t<curve type=\"1\" default=\"\(value)\" value=\"\(value)\">\n"
			+ "\t\t<min>-6</min>\n\t\t<max>8</max>\n"
			+ "\t</curve>\n</parameter>\n</ozml>\n"
		return s.data(using: .utf8)!
	}

	private static func patchTransformY(in objects: inout [Any], at index: Int, yPercent: Double) {
		guard let data = objects[index] as? Data,
			var ozml = String(data: data, encoding: .utf8)
		else { return }
		// Find and replace the Y curve value
		if let r = ozml.range(of: "value=\"18.518518518518519\"") {
			ozml.replaceSubrange(r, with: "value=\"\(yPercent)\"")
		} else {
			// Fallback: find last value= in the Y parameter curve
			var searchRange = ozml.startIndex..<ozml.endIndex
			var lastRange: Range<String.Index>?
			while let found = ozml.range(of: "value=\"", range: searchRange) {
				lastRange = found
				searchRange = found.upperBound..<ozml.endIndex
			}
			if let lr = lastRange {
				let afterQuote = ozml[lr.upperBound...]
				if let endQuote = afterQuote.firstIndex(of: "\"") {
					let fullRange = lr.lowerBound..<ozml.index(after: endQuote)
					ozml.replaceSubrange(fullRange, with: "value=\"\(yPercent)\"")
				}
			}
		}
		objects[index] = ozml.data(using: .utf8)!
	}

	struct FrameRate {
		let numerator: Int
		let denominator: Int
	}

	private static func parseFrameDuration(_ fd: String) -> FrameRate {
		let raw = fd.hasSuffix("s") ? String(fd.dropLast()) : fd
		guard let slash = raw.firstIndex(of: "/") else {
			return FrameRate(numerator: 1, denominator: 1)
		}
		let num = Int(Double(raw[raw.startIndex..<slash]) ?? 1)
		let den = Int(Double(raw[raw.index(after: slash)...]) ?? 1)
		return FrameRate(numerator: max(num, 1), denominator: max(den, 1))
	}

	private static func frames(seconds: Double, frameRate: FrameRate) -> Int {
		Int(round(seconds * Double(frameRate.denominator) / Double(frameRate.numerator)))
	}

	private static func rationalRange(
		startSeconds: Double, durationFrames: Int, frameRate: FrameRate
	) -> String {
		let startFrames = frames(seconds: startSeconds, frameRate: frameRate)
		let s = startFrames * frameRate.numerator
		let d = durationFrames * frameRate.numerator
		return "{(\(s)/\(frameRate.denominator)),(\(d)/\(frameRate.denominator))}"
	}

	private static func regenerateUUIDs(in objects: inout [Any], at indices: [Int]) {
		for idx in indices {
			guard idx < objects.count else { continue }
			if let str = objects[idx] as? String, str.count == 36, UUID(uuidString: str) != nil {
				objects[idx] = UUID().uuidString.uppercased()
			}
		}
	}

	private static func makeUID(_ value: Int) -> Any {
		let xml =
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>CF$UID</key><integer>\(value)</integer></dict></plist>"
		return try! PropertyListSerialization.propertyList(
			from: xml.data(using: .utf8)!, format: nil)
	}

	private static func uidValue(_ val: Any) -> Int? {
		let desc = "\(val)"
		guard desc.contains("CFKeyedArchiverUID"),
			let range = desc.range(of: "value = "),
			let end = desc[range.upperBound...].firstIndex(of: "}")
		else { return nil }
		return Int(desc[range.upperBound..<end])
	}

	private static func deepCopy(_ obj: Any, remap: [Int: Int]) -> Any {
		if let dict = obj as? [String: Any] {
			var result: [String: Any] = [:]
			for (key, val) in dict { result[key] = deepCopy(val, remap: remap) }
			return result
		}
		if let arr = obj as? [Any] { return arr.map { deepCopy($0, remap: remap) } }
		if let uid = uidValue(obj) { return makeUID(remap[uid] ?? uid) }
		return obj
	}
}
