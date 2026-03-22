/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Foundation

struct CaptionSegment {
	let clipIndex: Int
	let clipName: String
	let text: String
	let lines: [String]
	let startTime: Double
	let endTime: Double
}

enum CaptionBuilder {

	private static let minimumDuration: Double = 0.8
	private static let gapCloseThreshold: Double = 0.2

	static func build(
		rows: [AudioEditRow],
		clips: [FCPXMLParser.AudioClip],
		style: CaptionStyleSettings,
		textStyle: TextStyleSettings,
		exportWidth: Int,
		exportHeight: Int,
		language: String?
	) -> [CaptionSegment] {
		let sentences = rows.filter { !$0.isHeader && $0.isTranscribed }
		let maxLines = style.captionLines == .two ? 2 : 1
		let availableWidth = Double(exportWidth) * textStyle.textWidthPercent / 100.0
		let fcpFontSize = textStyle.textSize * Double(exportHeight) / 1080.0
		let font =
			NSFont(name: textStyle.textFont, size: CGFloat(fcpFontSize))
			?? NSFont.systemFont(ofSize: CGFloat(fcpFontSize))
		var segments: [CaptionSegment] = []

		for sentence in sentences {
			let words = sentence.editedWords ?? sentence.words
			guard !words.isEmpty else { continue }

			let timelineOffset: Double
			if sentence.clipIndex < clips.count {
				let clip = clips[sentence.clipIndex]
				timelineOffset = clip.start - clip.sourceStart
			} else {
				timelineOffset = 0
			}

			let processedWords = words.map { word in
				processWord(word.word, style: style, language: language)
			}

			let lineGroups = splitIntoLines(
				words: processedWords,
				timings: words,
				style: style,
				font: font,
				availableWidth: availableWidth
			)

			for group in lineGroups {
				let lines = group.lines
				let text = lines.joined(separator: "\n")
				segments.append(
					CaptionSegment(
						clipIndex: sentence.clipIndex,
						clipName: sentence.clipName,
						text: text,
						lines: lines,
						startTime: Double(group.startTime) + timelineOffset,
						endTime: Double(group.endTime) + timelineOffset
					))
			}
		}

		segments = mergeShortSegments(segments, maxLines: maxLines)
		segments = closeGaps(segments)
		segments = removeOverlaps(segments)

		return segments
	}

	private static func mergeShortSegments(
		_ segments: [CaptionSegment], maxLines: Int
	) -> [CaptionSegment] {
		guard !segments.isEmpty else { return segments }
		var result: [CaptionSegment] = []

		for segment in segments {
			let duration = segment.endTime - segment.startTime
			if duration < minimumDuration,
				let prev = result.last,
				prev.clipIndex == segment.clipIndex,
				segment.startTime - prev.endTime < gapCloseThreshold,
				prev.lines.count + segment.lines.count <= maxLines
			{
				let mergedLines = prev.lines + segment.lines
				let mergedText = mergedLines.joined(separator: "\n")
				result[result.count - 1] = CaptionSegment(
					clipIndex: segment.clipIndex,
					clipName: segment.clipName,
					text: mergedText,
					lines: mergedLines,
					startTime: prev.startTime,
					endTime: segment.endTime
				)
			} else if duration < minimumDuration {
				result.append(
					CaptionSegment(
						clipIndex: segment.clipIndex,
						clipName: segment.clipName,
						text: segment.text,
						lines: segment.lines,
						startTime: segment.startTime,
						endTime: segment.startTime + minimumDuration
					))
			} else {
				result.append(segment)
			}
		}

		return result
	}

	private static func closeGaps(_ segments: [CaptionSegment]) -> [CaptionSegment] {
		guard segments.count > 1 else { return segments }
		var result = segments

		for i in 0..<(result.count - 1) {
			guard result[i].clipIndex == result[i + 1].clipIndex else { continue }
			let gap = result[i + 1].startTime - result[i].endTime
			if gap > 0 && gap <= gapCloseThreshold {
				result[i] = CaptionSegment(
					clipIndex: result[i].clipIndex,
					clipName: result[i].clipName,
					text: result[i].text,
					lines: result[i].lines,
					startTime: result[i].startTime,
					endTime: result[i + 1].startTime
				)
			}
		}

		return result
	}

	private static func removeOverlaps(_ segments: [CaptionSegment]) -> [CaptionSegment] {
		guard segments.count > 1 else { return segments }
		var result = segments

		for i in 0..<(result.count - 1) {
			guard result[i].clipIndex == result[i + 1].clipIndex else { continue }
			if result[i].endTime > result[i + 1].startTime {
				result[i] = CaptionSegment(
					clipIndex: result[i].clipIndex,
					clipName: result[i].clipName,
					text: result[i].text,
					lines: result[i].lines,
					startTime: result[i].startTime,
					endTime: result[i + 1].startTime
				)
			}
		}

		return result
	}

	private struct LineGroup {
		let lines: [String]
		let startTime: Float
		let endTime: Float
	}

	private static func processWord(
		_ raw: String,
		style: CaptionStyleSettings,
		language: String?
	) -> String {
		var word = raw.trimmingCharacters(in: .whitespaces)

		let isCensored =
			style.censorProfanity && ProfanityFilter.isProfane(word, language: language)

		if isCensored {
			let base = word.trimmingCharacters(in: .punctuationCharacters)
			let grawlixChars: [Character] = ["@", "#", "$", "%", "&", "!"]
			let grawlix = String((0..<base.count).map { grawlixChars[$0 % grawlixChars.count] })
			word = grawlix
		}

		if !isCensored && style.stripPunctuation {
			word = stripPunctuation(word, keepQuestionMarks: style.keepQuestionMarks)
		}

		if style.allCaps {
			word = word.uppercased()
		}

		return word
	}

	private static func stripPunctuation(_ word: String, keepQuestionMarks: Bool) -> String {
		var result = ""
		for char in word {
			if char.isPunctuation || char.isSymbol {
				if keepQuestionMarks && char == "?" {
					result.append(char)
				}
			} else {
				result.append(char)
			}
		}
		return result
	}

	private static func splitIntoLines(
		words: [String],
		timings: [TranscriptionStore.StoredWord],
		style: CaptionStyleSettings,
		font: NSFont,
		availableWidth: Double
	) -> [LineGroup] {
		let maxWords = max(1, Int(style.maxWordsPerLine))
		let lineCount = style.captionLines == .two ? 2 : 1
		let attrs: [NSAttributedString.Key: Any] = [.font: font]
		let spaceWidth = (" " as NSString).size(withAttributes: attrs).width

		var wordWidths: [CGFloat] = []
		wordWidths.reserveCapacity(words.count)
		for word in words {
			wordWidths.append(
				word.isEmpty ? 0 : (word as NSString).size(withAttributes: attrs).width
			)
		}

		var groups: [LineGroup] = []
		var i = 0

		while i < words.count {
			var segmentLines: [String] = []
			let segmentStart = i

			for _ in 0..<lineCount {
				guard i < words.count else { break }
				var lineWords: [String] = []
				var wordCount = 0
				var lineWidth: CGFloat = 0

				while i < words.count && wordCount < maxWords {
					let word = words[i]
					guard !word.isEmpty else {
						i += 1
						continue
					}
					let wWidth = wordWidths[i]
					let candidateWidth =
						lineWords.isEmpty ? wWidth : lineWidth + spaceWidth + wWidth
					if !lineWords.isEmpty && candidateWidth > CGFloat(availableWidth) {
						break
					}
					lineWords.append(word)
					lineWidth = candidateWidth
					wordCount += 1
					i += 1
				}

				if !lineWords.isEmpty {
					segmentLines.append(lineWords.joined(separator: " "))
				}
			}

			if !segmentLines.isEmpty && i > segmentStart {
				let segTimings = Array(timings[segmentStart..<i])
				groups.append(
					LineGroup(
						lines: segmentLines,
						startTime: segTimings.first!.start,
						endTime: segTimings.last!.end
					))
			}
		}

		return groups
	}
}
