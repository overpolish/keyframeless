/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import CoreMedia
import Foundation

enum FCPXMLBuilder {

	struct ExportFormat {
		let width: Int
		let height: Int
		let frameDuration: String

		var formatName: String {
			"FFVideoFormat\(width)x\(height)p\(fpsLabel)"
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

	static func build(
		segments: [CaptionSegment],
		textStyle: TextStyleSettings,
		format: ExportFormat
	) -> String {
		guard !segments.isEmpty else {
			return emptyXML(format: format)
		}

		let lastEnd = segments.map(\.endTime).max() ?? 0
		let totalDuration = rationalTime(lastEnd, frameDuration: format.frameDuration)
		let fontSize = max(10, Int(textStyle.textSize))
		let yPosition = textYOffset(percent: textStyle.textYPosition)
		let fd = format.frameDuration

		var clipGroups: [(clipIndex: Int, clipName: String, segments: [CaptionSegment])] = []
		for segment in segments {
			if let last = clipGroups.last, last.clipIndex == segment.clipIndex {
				clipGroups[clipGroups.count - 1].segments.append(segment)
			} else {
				clipGroups.append(
					(clipIndex: segment.clipIndex, clipName: segment.clipName, segments: [segment]))
			}
		}

		var spineElements: [String] = []
		var tsCounter = 0

		for (laneIndex, group) in clipGroups.enumerated() {
			let lane = laneIndex + 1
			let sorted = group.segments.sorted { $0.startTime < $1.startTime }
			guard let first = sorted.first else { continue }

			let spineOffset = rationalTime(first.startTime, frameDuration: fd)
			var elements: [String] = []
			var cursor = first.startTime

			for segment in sorted {
				let gapDuration = segment.startTime - cursor
				if gapDuration > 0.001 {
					elements.append(
						"\t\t\t\t\t\t\t\t<gap duration=\"\(rationalTime(gapDuration, frameDuration: fd))\" />"
					)
				}

				tsCounter += 1
				let tsID = "ts\(tsCounter)"
				let segDuration = segment.endTime - segment.startTime
				elements.append(
					"\t\t\t\t\t\t\t\t<title ref=\"r2\" duration=\"\(rationalTime(segDuration, frameDuration: fd))\" name=\"\(xmlEscape(segment.lines.first ?? ""))\">\n"
						+ "\t\t\t\t\t\t\t\t\t<param name=\"Size\" key=\"9999/999166631/999166633/5/999166635/3\" value=\"\(fontSize)\" />\n"
						+ "\t\t\t\t\t\t\t\t\t<text>\n"
						+ "\t\t\t\t\t\t\t\t\t\t<text-style ref=\"\(tsID)\">\(xmlEscape(segment.text))</text-style>\n"
						+ "\t\t\t\t\t\t\t\t\t</text>\n"
						+ "\t\t\t\t\t\t\t\t\t<text-style-def id=\"\(tsID)\">\n"
						+ "\t\t\t\t\t\t\t\t\t\t<text-style font=\"\(xmlEscape(textStyle.textFont))\" fontSize=\"\(fontSize)\" fontFace=\"Regular\"\n"
						+ "\t\t\t\t\t\t\t\t\t\t\tfontColor=\"1 1 1 1\" alignment=\"center\" />\n"
						+ "\t\t\t\t\t\t\t\t\t</text-style-def>\n"
						+ "\t\t\t\t\t\t\t\t\t<adjust-transform position=\"0 \(yPosition)\" />\n"
						+ "\t\t\t\t\t\t\t\t</title>"
				)
				cursor = segment.endTime
			}

			let childrenXML = elements.joined(separator: "\n")
			spineElements.append(
				"\t\t\t\t\t\t\t<spine lane=\"\(lane)\" offset=\"\(spineOffset)\">\n"
					+ childrenXML + "\n"
					+ "\t\t\t\t\t\t\t</spine>"
			)
		}

		let spinesXML = spineElements.joined(separator: "\n")

		let xml =
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
			+ "<!DOCTYPE fcpxml SYSTEM \"https://raw.githubusercontent.com/CommandPost/CommandPost/refs/heads/develop/src/extensions/cp/apple/fcpxml/dtd/FCPXMLv1_14.dtd\">\n"
			+ "<fcpxml version=\"1.14\">\n"
			+ "\t<resources>\n"
			+ "\t\t<format id=\"r1\" name=\"\(format.formatName)\" frameDuration=\"\(fd)\" width=\"\(format.width)\" height=\"\(format.height)\" />\n"
			+ "\t\t<effect id=\"r2\" name=\"Basic Title\"\n"
			+ "\t\t\tuid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\" />\n"
			+ "\t\t<media id=\"r3\" name=\"Captions\">\n"
			+ "\t\t\t<sequence format=\"r1\" duration=\"\(totalDuration)\">\n"
			+ "\t\t\t\t<spine>\n"
			+ "\t\t\t\t\t<gap duration=\"\(totalDuration)\">\n"
			+ spinesXML + "\n"
			+ "\t\t\t\t\t</gap>\n"
			+ "\t\t\t\t</spine>\n"
			+ "\t\t\t</sequence>\n"
			+ "\t\t</media>\n"
			+ "\t</resources>\n"
			+ "\t<ref-clip ref=\"r3\" duration=\"\(totalDuration)\" />\n"
			+ "</fcpxml>"
		return xml
	}

	private static func emptyXML(format: ExportFormat) -> String {
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
			+ "<!DOCTYPE fcpxml SYSTEM \"https://raw.githubusercontent.com/CommandPost/CommandPost/refs/heads/develop/src/extensions/cp/apple/fcpxml/dtd/FCPXMLv1_14.dtd\">\n"
			+ "<fcpxml version=\"1.14\">\n"
			+ "\t<resources>\n"
			+ "\t\t<format id=\"r1\" name=\"\(format.formatName)\" frameDuration=\"\(format.frameDuration)\" width=\"\(format.width)\" height=\"\(format.height)\" />\n"
			+ "\t</resources>\n"
			+ "</fcpxml>"
	}

	private static func rationalTime(_ seconds: Double, frameDuration: String) -> String {
		let raw = frameDuration.hasSuffix("s") ? String(frameDuration.dropLast()) : frameDuration
		guard let slash = raw.firstIndex(of: "/") else {
			return "\(Int(round(seconds)))s"
		}
		let num = Int(Double(raw[raw.startIndex..<slash]) ?? 1)
		let den = Int(Double(raw[raw.index(after: slash)...]) ?? 1)
		guard num > 0 else { return "0s" }
		let frames = Int(round(seconds * Double(den) / Double(num)))
		return "\(frames * num)/\(den)s"
	}

	private static func textYOffset(percent: Double) -> String {
		let y = percent - 50.0
		return String(format: "%.1f", y)
	}

	private static func xmlEscape(_ string: String) -> String {
		string
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}
}
