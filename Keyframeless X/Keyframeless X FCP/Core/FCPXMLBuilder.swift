/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import CoreMedia
import Foundation

enum FCPXMLBuilder {

	struct ExportFormat {
		let width: Int
		let height: Int
		let frameDuration: String

		var formatName: String {
			let resolution: String
			switch (width, height) {
			case (7680, 4320): resolution = "8K"
			case (3840, 2160): resolution = "4K"
			default: resolution = "\(height)"
			}
			return "FFVideoFormat\(resolution)p\(fpsLabel)"
		}

		private var fpsLabel: String {
			let raw =
				frameDuration.hasSuffix("s") ? String(frameDuration.dropLast()) : frameDuration
			guard let slash = raw.firstIndex(of: "/") else { return "30" }
			let num = Double(raw[raw.startIndex..<slash]) ?? 1
			let den = Double(raw[raw.index(after: slash)...]) ?? 1
			guard num > 0 else { return "30" }
			let fps = den / num
			if fps.truncatingRemainder(dividingBy: 1) == 0 {
				return "\(Int(fps))"
			}
			return String(format: "%.2f", fps)
		}
	}

	struct PublishedParamEntry {
		let name: String
		let key: String
		let value: String
	}

	static func build(
		storylines: [[CaptionSegment]],
		textStyle: TextStyleSettings,
		format: ExportFormat,
		template: CaptionTemplate = .basicTitle,
		publishedParams: [PublishedParamEntry] = [],
		perWordStartsAtZero: Bool = false
	) -> String {
		let allSegments = storylines.flatMap { $0 }
		guard !allSegments.isEmpty else {
			return emptyXML(format: format)
		}

		let lastEnd = allSegments.map(\.endTime).max() ?? 0
		let fd = format.frameDuration
		let frameRate = parseFrameDuration(fd)
		let totalDuration = rationalTime(seconds: lastEnd, frameRate: frameRate)
		let fontSize = max(10, Int(textStyle.textSize))
		let yPosition = textYOffset(percent: textStyle.textYPosition)
		let font = fontInfo(postScriptName: textStyle.textFont)
		let escapedFamily = xmlEscape(font.familyName)
		let escapedFace = xmlEscape(font.faceName)
		let fontColor = textStyle.fontColorString

		var xml = ""
		let estimatedSize = allSegments.count * 512 + 512
		xml.reserveCapacity(estimatedSize)

		xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		xml +=
			"<!DOCTYPE fcpxml SYSTEM \"https://raw.githubusercontent.com/CommandPost/CommandPost/refs/heads/develop/src/extensions/cp/apple/fcpxml/dtd/FCPXMLv1_14.dtd\">\n"
		xml += "<fcpxml version=\"1.14\">\n"
		xml += "\t<resources>\n"
		xml +=
			"\t\t<format id=\"r1\" frameDuration=\"\(fd)\" width=\"\(format.width)\" height=\"\(format.height)\" colorSpace=\"1-1-1 (Rec. 709)\" />\n"
		xml += "\t\t<effect id=\"r2\" name=\"\(xmlEscape(template.name))\"\n"
		xml +=
			"\t\t\tuid=\"\(xmlEscape(template.uid))\" />\n"
		xml += "\t</resources>\n"
		xml += "\t<library>\n"
		xml += "\t\t<event name=\"Captions\">\n"
		xml += "\t\t\t<project name=\"Captions\">\n"
		xml += "\t\t\t\t<sequence format=\"r1\" duration=\"\(totalDuration)\">\n"
		xml += "\t\t\t\t\t<spine>\n"
		xml += "\t\t\t\t\t\t<gap duration=\"\(totalDuration)\">\n"

		var tsCounter = 0

		for (slIndex, segments) in storylines.enumerated() {
			let lane = slIndex + 1
			let sorted = segments.sorted { $0.startTime < $1.startTime }

			for (si, segment) in sorted.enumerated() {
				tsCounter += 1
				let tsID = "ts\(tsCounter)"
				let mediaStart = 3600.0
				let offsetFrames = frames(seconds: segment.startTime, frameRate: frameRate)
				let offset = rationalFromFrames(offsetFrames, frameRate: frameRate)
				let durationStr: String
				if si + 1 < sorted.count,
					sorted[si + 1].startTime - segment.endTime < 0.001
				{
					let nextFrames = frames(
						seconds: sorted[si + 1].startTime, frameRate: frameRate)
					durationStr = rationalFromFrames(
						nextFrames - offsetFrames, frameRate: frameRate)
				} else {
					durationStr = rationalTime(
						seconds: segment.endTime - segment.startTime, frameRate: frameRate)
				}
				xml +=
					"\t\t\t\t\t\t\t<title lane=\"\(lane)\" offset=\"\(offset)\" ref=\"r2\" duration=\"\(durationStr)\" start=\"\(rationalTime(seconds: mediaStart, frameRate: frameRate))\" name=\"\(xmlEscape(segment.lines.first ?? ""))\" role=\"Captions.Captions-1\">\n"
				let wordCount = segment.wordStarts.count
				if wordCount > 0 && template.supportsPerWordAnimation,
					let paramName = template.wordsInParamName,
					let keyPath = template.wordsInKeyPath
				{
					xml +=
						"\t\t\t\t\t\t\t\t<param name=\"\(paramName)\" key=\"\(keyPath)\">\n"
					xml += "\t\t\t\t\t\t\t\t\t<keyframeAnimation>\n"
					let divisor = Double(wordCount)
					for (i, wordStart) in segment.wordStarts.enumerated() {
						let wordOffset = wordStart - segment.startTime
						let time = rationalTime(
							seconds: mediaStart + wordOffset, frameRate: frameRate)
						let value =
							perWordStartsAtZero
							? Double(i) / divisor
							: Double(i + 1) / divisor
						let valueStr =
							value == 1 ? "1" : String(format: "%g", value)
						xml +=
							"\t\t\t\t\t\t\t\t\t\t<keyframe time=\"\(time)\" value=\"\(valueStr)\"/>\n"
					}
					xml += "\t\t\t\t\t\t\t\t\t</keyframeAnimation>\n"
					xml += "\t\t\t\t\t\t\t\t</param>\n"
				}
				for pp in publishedParams {
					xml +=
						"\t\t\t\t\t\t\t\t<param name=\"\(xmlEscape(pp.name))\" key=\"\(pp.key)\" value=\"\(pp.value)\"/>\n"
				}
				xml += "\t\t\t\t\t\t\t\t<text>\n"
				xml +=
					"\t\t\t\t\t\t\t\t\t<text-style ref=\"\(tsID)\">\(xmlEscape(segment.text))</text-style>\n"
				xml += "\t\t\t\t\t\t\t\t</text>\n"
				xml += "\t\t\t\t\t\t\t\t<text-style-def id=\"\(tsID)\">\n"
				xml +=
					"\t\t\t\t\t\t\t\t\t<text-style font=\"\(escapedFamily)\" fontSize=\"\(fontSize)\" fontFace=\"\(escapedFace)\" fontColor=\"\(fontColor)\" alignment=\"center\" />\n"
				xml += "\t\t\t\t\t\t\t\t</text-style-def>\n"
				xml += "\t\t\t\t\t\t\t\t<adjust-transform position=\"0 \(yPosition)\" />\n"
				xml += "\t\t\t\t\t\t\t</title>\n"
			}
		}

		xml += "\t\t\t\t\t\t</gap>\n"
		xml += "\t\t\t\t\t</spine>\n"
		xml += "\t\t\t\t</sequence>\n"
		xml += "\t\t\t</project>\n"
		xml += "\t\t</event>\n"
		xml += "\t</library>\n"
		xml += "</fcpxml>"
		return xml
	}

	private static func emptyXML(format: ExportFormat) -> String {
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
			+ "<!DOCTYPE fcpxml SYSTEM \"https://raw.githubusercontent.com/CommandPost/CommandPost/refs/heads/develop/src/extensions/cp/apple/fcpxml/dtd/FCPXMLv1_14.dtd\">\n"
			+ "<fcpxml version=\"1.14\">\n"
			+ "\t<resources>\n"
			+ "\t\t<format id=\"r1\" frameDuration=\"\(format.frameDuration)\" width=\"\(format.width)\" height=\"\(format.height)\" colorSpace=\"1-1-1 (Rec. 709)\" />\n"
			+ "\t</resources>\n"
			+ "</fcpxml>"
	}

	struct FrameRate {
		let numerator: Int
		let denominator: Int
	}

	private static func parseFrameDuration(_ frameDuration: String) -> FrameRate {
		let raw = frameDuration.hasSuffix("s") ? String(frameDuration.dropLast()) : frameDuration
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

	private static func rationalFromFrames(_ frameCount: Int, frameRate: FrameRate) -> String {
		"\(frameCount * frameRate.numerator)/\(frameRate.denominator)s"
	}

	private static func rationalTime(seconds: Double, frameRate: FrameRate) -> String {
		let frames = Int(
			round(seconds * Double(frameRate.denominator) / Double(frameRate.numerator)))
		return "\(frames * frameRate.numerator)/\(frameRate.denominator)s"
	}

	private static func textYOffset(percent: Double) -> String {
		let y = percent - 50.0
		return String(format: "%.1f", y)
	}

	struct FontInfo {
		let familyName: String
		let faceName: String
		let paramValue: String
	}

	private static var fontInfoCache: [String: FontInfo] = [:]

	static func fontInfo(postScriptName: String) -> FontInfo {
		if let cached = fontInfoCache[postScriptName] { return cached }

		let manager = NSFontManager.shared
		let families = manager.availableFontFamilies

		guard let font = NSFont(name: postScriptName, size: 12) else {
			let info = FontInfo(familyName: postScriptName, faceName: "Regular", paramValue: "0 0")
			fontInfoCache[postScriptName] = info
			return info
		}

		let familyName = font.familyName ?? postScriptName
		let familyIndex = families.firstIndex(of: familyName) ?? 0

		let members = manager.availableMembers(ofFontFamily: familyName) ?? []
		var faceIndex = 0
		var faceName = "Regular"
		for (i, member) in members.enumerated() {
			if (member[0] as? String) == postScriptName {
				faceIndex = i
				faceName = (member[1] as? String) ?? "Regular"
				break
			}
		}

		let info = FontInfo(
			familyName: familyName,
			faceName: faceName,
			paramValue: "\(familyIndex) \(faceIndex)"
		)
		fontInfoCache[postScriptName] = info
		return info
	}

	private static func xmlEscape(_ string: String) -> String {
		string
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}
}
