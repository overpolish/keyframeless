/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension FCPNativePasteboardBuilder {

	static let cloneIndices: [Int] = [
		15, 16, 17, 19,
		20, 21,
		22, 23, 26,
		31, 32, 33, 37,
		40, 41,
		45, 46, 48,
		51, 52, 54,
		59, 83, 84,
	]

	static func makeStoryline(
		into objects: inout [Any], items: [Any], lane: Int,
		anchorMediaTime: Double = 3600.0, frameRate: FrameRate
	) -> Any {
		let contentsIdx = objects.count
		objects.append(
			[
				"$class": makeUID(38),
				"NS.objects": items,
			] as [String: Any])

		let anchorPairIdx = objects.count
		let anchorFrames = frames(seconds: anchorMediaTime, frameRate: frameRate)
		let anchorTicks = anchorFrames * frameRate.numerator
		objects.append("{(0/1),(\(anchorTicks)/\(frameRate.denominator))}")

		let slIdx = objects.count
		objects.append(
			[
				"$class": makeUID(87),
				"anchorPair": makeUID(anchorPairIdx),
				"anchoredLane": lane as NSNumber,
				"aoFlagsMask": -1 as NSNumber,
				"containedItems": makeUID(contentsIdx),
				"displayName": makeUID(slIdx + 1),
				"isSpine": true as NSNumber,
				"persistentID": makeUID(slIdx + 2),
				"unclippedStart": makeUID(66),
				"videoProps": makeUID(67),
			] as [String: Any])
		objects.append("Storyline")
		objects.append(UUID().uuidString.uppercased())

		return makeUID(slIdx)
	}

	static func makeGap(
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

	static func cloneTitle(
		into objects: inout [Any],
		displayName: String,
		range: String,
		style: Style,
		mevClassIdx: Int,
		entries: [EffectValueEntry],
		isBasicTitle: Bool
	) -> Any {
		var remap: [Int: Int] = [:]
		let baseIdx = objects.count
		for (offset, origIdx) in cloneIndices.enumerated() {
			remap[origIdx] = baseIdx + offset
		}
		for origIdx in cloneIndices {
			objects.append(deepCopy(objects[origIdx], remap: remap))
		}
		if isBasicTitle { objects[remap[17]!] = displayName }
		objects[remap[19]!] = range
		regenerateUUIDs(in: &objects, at: Array(remap.values))

		patchTransformY(in: &objects, at: remap[54]!, yPercent: style.yPositionPercent - 50.0)

		addEffectValues(
			into: &objects, mevClassIdx: mevClassIdx, customEffectIdx: remap[22]!,
			entries: entries)

		if var t = objects[remap[15]!] as? [String: Any] {
			t.removeValue(forKey: "anchoredLane")
			t.removeValue(forKey: "anchorPair")
			objects[remap[15]!] = t
		}

		return makeUID(remap[15]!)
	}

	static func addEffectValues(
		into objects: inout [Any],
		mevClassIdx: Int,
		customEffectIdx: Int,
		entries: [EffectValueEntry]
	) {
		guard !entries.isEmpty else { return }
		var evUIDs: [Any] = []
		for entry in entries {
			evUIDs.append(
				addEffectValue(
					into: &objects, classIdx: mevClassIdx,
					key: entry.key, data: entry.data))
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

	static func addEffectValue(
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

	static func patchTransformY(in objects: inout [Any], at index: Int, yPercent: Double) {
		guard let data = objects[index] as? Data,
			var ozml = String(data: data, encoding: .utf8)
		else { return }
		if let r = ozml.range(of: "value=\"18.518518518518519\"") {
			ozml.replaceSubrange(r, with: "value=\"\(yPercent)\"")
		} else {
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

	static func regenerateUUIDs(in objects: inout [Any], at indices: [Int]) {
		for idx in indices {
			guard idx < objects.count else { continue }
			if let str = objects[idx] as? String, str.count == 36, UUID(uuidString: str) != nil {
				objects[idx] = UUID().uuidString.uppercased()
			}
		}
	}

	static func makeUID(_ value: Int) -> Any {
		let xml =
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>CF$UID</key><integer>\(value)</integer></dict></plist>"
		return try! PropertyListSerialization.propertyList(
			from: xml.data(using: .utf8)!, format: nil)
	}

	static func uidValue(_ val: Any) -> Int? {
		let desc = "\(val)"
		guard desc.contains("CFKeyedArchiverUID"),
			let range = desc.range(of: "value = "),
			let end = desc[range.upperBound...].firstIndex(of: "}")
		else { return nil }
		return Int(desc[range.upperBound..<end])
	}

	static func deepCopy(_ obj: Any, remap: [Int: Int]) -> Any {
		if let dict = obj as? [String: Any] {
			var result: [String: Any] = [:]
			for (key, val) in dict { result[key] = deepCopy(val, remap: remap) }
			return result
		}
		if let arr = obj as? [Any] { return arr.map { deepCopy($0, remap: remap) } }
		if let uid = uidValue(obj) { return makeUID(remap[uid] ?? uid) }
		return obj
	}

	static func frames(seconds: Double, frameRate: FrameRate) -> Int {
		Int(round(seconds * Double(frameRate.denominator) / Double(frameRate.numerator)))
	}

	static func parseFrameDuration(_ fd: String) -> FrameRate {
		let raw = fd.hasSuffix("s") ? String(fd.dropLast()) : fd
		guard let slash = raw.firstIndex(of: "/") else {
			return FrameRate(numerator: 1, denominator: 1)
		}
		let num = Int(Double(raw[raw.startIndex..<slash]) ?? 1)
		let den = Int(Double(raw[raw.index(after: slash)...]) ?? 1)
		return FrameRate(numerator: max(num, 1), denominator: max(den, 1))
	}

	static func rationalRange(
		startSeconds: Double, durationFrames: Int, frameRate: FrameRate
	) -> String {
		let startFrames = frames(seconds: startSeconds, frameRate: frameRate)
		let s = startFrames * frameRate.numerator
		let d = durationFrames * frameRate.numerator
		return "{(\(s)/\(frameRate.denominator)),(\(d)/\(frameRate.denominator))}"
	}
}
