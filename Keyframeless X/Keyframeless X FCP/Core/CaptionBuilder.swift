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
	let wordStarts: [Double]
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
				availableWidth: availableWidth,
				forcedBreaks: Set(sentence.captionBreaks)
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
						endTime: Double(group.endTime) + timelineOffset,
						wordStarts: group.wordStarts.map { Double($0) + timelineOffset }
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
		var i = 0

		while i < segments.count {
			let segment = segments[i]
			let duration = segment.endTime - segment.startTime

			if duration < minimumDuration,
				i + 1 < segments.count,
				segments[i + 1].clipIndex == segment.clipIndex,
				segments[i + 1].startTime - segment.endTime < gapCloseThreshold,
				segment.lines.count + segments[i + 1].lines.count <= maxLines
			{
				let next = segments[i + 1]
				let mergedLines = segment.lines + next.lines
				let mergedText = mergedLines.joined(separator: "\n")
				result.append(
					CaptionSegment(
						clipIndex: segment.clipIndex,
						clipName: segment.clipName,
						text: mergedText,
						lines: mergedLines,
						startTime: segment.startTime,
						endTime: next.endTime,
						wordStarts: segment.wordStarts + next.wordStarts
					))
				i += 2
			} else if duration < minimumDuration {
				result.append(
					CaptionSegment(
						clipIndex: segment.clipIndex,
						clipName: segment.clipName,
						text: segment.text,
						lines: segment.lines,
						startTime: segment.startTime,
						endTime: segment.startTime + minimumDuration,
						wordStarts: segment.wordStarts
					))
				i += 1
			} else {
				result.append(segment)
				i += 1
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
					endTime: result[i + 1].startTime,
					wordStarts: result[i].wordStarts
				)
			}
		}

		return result
	}

	struct OverlapRegion {
		let start: Double
		let end: Double
	}

	static func overlapRegions(_ segments: [CaptionSegment]) -> [OverlapRegion] {
		let sorted = segments.sorted { $0.startTime < $1.startTime }
		var regions: [OverlapRegion] = []
		var maxEnd = -Double.infinity
		for seg in sorted {
			if seg.startTime < maxEnd {
				regions.append(
					OverlapRegion(
						start: seg.startTime,
						end: min(maxEnd, seg.endTime)
					))
			}
			maxEnd = max(maxEnd, seg.endTime)
		}
		return regions
	}

	static func hasOverlaps(_ segments: [CaptionSegment]) -> Bool {
		let sorted = segments.sorted { $0.startTime < $1.startTime }
		var maxEnd = -Double.infinity
		for seg in sorted {
			if seg.startTime < maxEnd { return true }
			maxEnd = max(maxEnd, seg.endTime)
		}
		return false
	}

	static func formatSRT(_ segments: [CaptionSegment]) -> String {
		let sorted = segments.sorted { $0.startTime < $1.startTime }
		var lines: [String] = []
		for (i, seg) in sorted.enumerated() {
			lines.append("\(i + 1)")
			lines.append("\(srtTimestamp(seg.startTime)) --> \(srtTimestamp(seg.endTime))")
			lines.append(seg.text)
			lines.append("")
		}
		return lines.joined(separator: "\n")
	}

	private static func srtTimestamp(_ seconds: Double) -> String {
		let total = max(0, seconds)
		let h = Int(total) / 3600
		let m = (Int(total) % 3600) / 60
		let s = Int(total) % 60
		let ms = Int((total - Double(Int(total))) * 1000)
		return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
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
					endTime: result[i + 1].startTime,
					wordStarts: result[i].wordStarts
				)
			}
		}

		return result
	}

	private struct LineGroup {
		let lines: [String]
		let startTime: Float
		let endTime: Float
		let wordStarts: [Float]
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
			let dashes = String(repeating: "-", count: max(1, base.count - 1))
			word = String(base.prefix(1)) + dashes
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
				} else if char == "'" || char == "\u{2019}" {
					result.append(char)
				}
			} else {
				result.append(char)
			}
		}
		return result
	}

	private static let breakSentenceEndChars = CharacterSet(charactersIn: ".!?")
	private static let breakClauseChars = CharacterSet(charactersIn: ".,;:!?")
	private static let breakPauseThreshold: Float = 0.3

	private static func naturalBreakScore(
		afterWordAt idx: Int,
		timings: [TranscriptionStore.StoredWord],
		totalWordCount: Int
	) -> Int {
		var score = 0
		let trimmed = timings[idx].word.trimmingCharacters(in: .whitespaces)
		if let lastScalar = trimmed.unicodeScalars.last {
			if breakSentenceEndChars.contains(lastScalar) {
				score = 3
			} else if breakClauseChars.contains(lastScalar) {
				score = 1
			}
		}
		if idx + 1 < totalWordCount {
			let gap = timings[idx + 1].start - timings[idx].end
			if gap > breakPauseThreshold {
				score = max(score, 2)
			}
		}
		return score
	}

	private static func splitIntoLines(
		words: [String],
		timings: [TranscriptionStore.StoredWord],
		style: CaptionStyleSettings,
		font: NSFont,
		availableWidth: Double,
		forcedBreaks: Set<Int> = []
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
			let segStart = i

			// Step 1: Greedily determine how many words fit in this segment
			var greedyEnd = segStart
			for _ in 0..<lineCount {
				guard greedyEnd < words.count else { break }
				var lineWidth: CGFloat = 0
				var wordCount = 0
				while greedyEnd < words.count && wordCount < maxWords {
					guard !words[greedyEnd].isEmpty else {
						greedyEnd += 1
						continue
					}
					let wWidth = wordWidths[greedyEnd]
					let candidateWidth =
						wordCount == 0 ? wWidth : lineWidth + spaceWidth + wWidth
					if wordCount > 0 && candidateWidth > CGFloat(availableWidth) { break }
					lineWidth = candidateWidth
					wordCount += 1
					greedyEnd += 1
				}
			}

			guard greedyEnd > segStart else {
				i += 1
				continue
			}

			// Step 2: Find break point — forced breaks take priority
			var segEnd = greedyEnd
			let firstForced = forcedBreaks.filter { $0 > segStart && $0 < greedyEnd }
				.min()
			if let firstForced {
				segEnd = firstForced
			} else if segEnd < words.count {
				let nonEmptyCount = (segStart..<segEnd).filter({ !words[$0].isEmpty }).count
				let minKeep = max(1, nonEmptyCount / 2)
				var bestBreakAt = -1
				var bestScore = 0
				var seen = 0

				for j in segStart..<segEnd {
					guard !words[j].isEmpty else { continue }
					seen += 1
					guard seen >= minKeep else { continue }
					let score = naturalBreakScore(
						afterWordAt: j, timings: timings, totalWordCount: words.count)
					if score > bestScore {
						bestScore = score
						bestBreakAt = j + 1
					}
				}

				if bestScore > 0 && bestBreakAt > segStart && bestBreakAt < segEnd {
					segEnd = bestBreakAt
				}
			}

			// Step 3: Layout words[segStart..<segEnd] into lines
			var segmentLines: [String] = []
			var segmentWordStarts: [Float] = []
			var lastWordIdx = segStart
			var wi = segStart

			for _ in 0..<lineCount {
				guard wi < segEnd else { break }
				var lineWords: [String] = []
				var lineWidth: CGFloat = 0
				var wordCount = 0

				while wi < segEnd && wordCount < maxWords {
					guard !words[wi].isEmpty else {
						wi += 1
						continue
					}
					let wWidth = wordWidths[wi]
					let candidateWidth =
						lineWords.isEmpty ? wWidth : lineWidth + spaceWidth + wWidth
					if !lineWords.isEmpty && candidateWidth > CGFloat(availableWidth) { break }
					segmentWordStarts.append(timings[wi].start)
					lineWords.append(words[wi])
					lineWidth = candidateWidth
					wordCount += 1
					lastWordIdx = wi
					wi += 1
				}

				if !lineWords.isEmpty {
					segmentLines.append(lineWords.joined(separator: " "))
				}
			}

			if !segmentLines.isEmpty {
				groups.append(
					LineGroup(
						lines: segmentLines,
						startTime: timings[segStart].start,
						endTime: timings[lastWordIdx].end,
						wordStarts: segmentWordStarts
					))
			}

			i = segEnd
		}

		return groups
	}
}
