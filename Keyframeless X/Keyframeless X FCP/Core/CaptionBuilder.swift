/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

	private static let minimumDuration: Double = 0.15
	private static let gapCloseThreshold: Double = 0.15

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
		if style.noGaps {
			segments = closeAllGaps(segments)
		}

		return segments
	}

	private static func mergeShortSegments(
		_ segments: [CaptionSegment], maxLines: Int
	) -> [CaptionSegment] {
		guard !segments.isEmpty else { return segments }
		var result: [CaptionSegment] = []
		var i = 0

		while i < segments.count {
			var merged = segments[i]
			var duration = merged.endTime - merged.startTime

			while duration < minimumDuration,
				i + 1 < segments.count,
				segments[i + 1].clipIndex == merged.clipIndex,
				segments[i + 1].startTime - merged.endTime < gapCloseThreshold
			{
				let next = segments[i + 1]
				let combinedLines = merged.lines.count + next.lines.count
				let mergedLines: [String]
				if combinedLines <= maxLines {
					mergedLines = merged.lines + next.lines
				} else {
					let lastLine = merged.lines.last ?? ""
					let nextFirst = next.lines.first ?? ""
					let joined = lastLine.isEmpty ? nextFirst : "\(lastLine) \(nextFirst)"
					var lines = Array(merged.lines.dropLast())
					lines.append(joined)
					lines.append(contentsOf: next.lines.dropFirst())
					mergedLines = lines
				}
				merged = CaptionSegment(
					clipIndex: merged.clipIndex,
					clipName: merged.clipName,
					text: mergedLines.joined(separator: "\n"),
					lines: mergedLines,
					startTime: merged.startTime,
					endTime: next.endTime,
					wordStarts: merged.wordStarts + next.wordStarts
				)
				i += 1
				duration = merged.endTime - merged.startTime
			}

			if duration < minimumDuration {
				merged = CaptionSegment(
					clipIndex: merged.clipIndex,
					clipName: merged.clipName,
					text: merged.text,
					lines: merged.lines,
					startTime: merged.startTime,
					endTime: merged.startTime + minimumDuration,
					wordStarts: merged.wordStarts
				)
			}

			result.append(merged)
			i += 1
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

	static func closeAllGaps(_ segments: [CaptionSegment]) -> [CaptionSegment] {
		guard segments.count > 1 else { return segments }
		var result = segments.sorted { $0.startTime < $1.startTime }

		for i in 0..<(result.count - 1) {
			let gap = result[i + 1].startTime - result[i].endTime
			if gap > 0 {
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
		let epsilon = 0.001
		var maxEnd = -Double.infinity
		for seg in sorted {
			if seg.startTime < maxEnd - epsilon {
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

	/// Splits each segment so its single-line text fits within `maxChars`, for CEA-608's fixed
	/// character grid (a single row holds at most 32 columns). Breaks at word boundaries, keeping
	/// speech sync via wordStarts when they line up, otherwise dividing the duration by character
	/// share. Words longer than `maxChars` are hard-split.
	/// CEA-608-aware splitter: wraps into up to `maxLines` rows of ≤`maxCharsPerLine` chars each,
	/// spilling overflow into a new segment. Preserves multi-line structure in `seg.lines` so the
	/// pasteboard builder can fan PCs across the CEA-608 grid rows; the legacy single-line
	/// `splitToMaxChars` collapsed lines before splitting which forced single-row output.
	static func splitCEA608Multiline(
		_ segments: [CaptionSegment], maxCharsPerLine: Int, maxLines: Int
	) -> [CaptionSegment] {
		precondition(maxLines >= 1)
		var out: [CaptionSegment] = []
		for seg in segments {
			// Respect CaptionBuilder's existing line split (driven by maxWordsPerLine + captionLines):
			// if every row already fits the char cap and the row count fits the line cap, pass through
			// unchanged so the user's word-break choice survives. Only repack when a row overflows.
			let fitsRowCap = seg.lines.allSatisfy { $0.count <= maxCharsPerLine }
			if fitsRowCap && seg.lines.count <= maxLines && !seg.lines.isEmpty {
				out.append(seg)
				continue
			}
			let words = seg.lines.joined(separator: " ").split(separator: " ").map(String.init)
			guard !words.isEmpty else {
				out.append(seg)
				continue
			}

			// Greedy pack: build groups of up to maxLines rows; each row ≤ maxCharsPerLine.
			// A word longer than the line cap is hard-chunked into multiple rows.
			var groups: [(rows: [String], startWord: Int)] = []
			var curRows: [String] = []
			var curRow = ""
			var curRowStartWord = 0
			var curGroupStartWord = 0
			func flushRow() {
				if !curRow.isEmpty {
					curRows.append(curRow)
					curRow = ""
				}
			}
			func flushGroup() {
				flushRow()
				if !curRows.isEmpty {
					groups.append((curRows, curGroupStartWord))
					curRows = []
				}
			}
			for (wi, w) in words.enumerated() {
				if w.count > maxCharsPerLine {
					flushRow()
					if curRows.count >= maxLines {
						flushGroup()
						curGroupStartWord = wi
					}
					var chunk = w
					while !chunk.isEmpty {
						let take = min(maxCharsPerLine, chunk.count)
						let idx = chunk.index(chunk.startIndex, offsetBy: take)
						curRows.append(String(chunk[..<idx]))
						chunk = String(chunk[idx...])
						if curRows.count >= maxLines && !chunk.isEmpty {
							flushGroup()
							curGroupStartWord = wi
						}
					}
					continue
				}
				let need = (curRow.isEmpty ? 0 : 1) + w.count
				if curRow.count + need <= maxCharsPerLine {
					if curRow.isEmpty {
						if curRows.isEmpty { curGroupStartWord = wi }
						curRowStartWord = wi
					}
					curRow = curRow.isEmpty ? w : "\(curRow) \(w)"
				} else {
					flushRow()
					if curRows.count >= maxLines {
						flushGroup()
						curGroupStartWord = wi
					}
					if curRows.isEmpty { curGroupStartWord = wi }
					curRowStartWord = wi
					curRow = w
				}
				_ = curRowStartWord  // suppress unused warning; reserved for future per-row anchoring
			}
			flushGroup()

			// Time-split: prefer wordStarts alignment when intact, fall back to char proportion.
			let aligned = seg.wordStarts.count == words.count
			let totalDur = seg.endTime - seg.startTime
			let totalChars = groups.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.count } }
			var t = seg.startTime
			for (gi, g) in groups.enumerated() {
				let start: Double
				let end: Double
				if aligned {
					start = seg.wordStarts[g.startWord]
					end =
						gi == groups.count - 1
						? seg.endTime
						: seg.wordStarts[groups[gi + 1].startWord]
				} else {
					start = t
					let groupChars = g.rows.reduce(0) { $0 + $1.count }
					let frac =
						totalChars > 0
						? Double(groupChars) / Double(totalChars)
						: 1.0 / Double(groups.count)
					end = gi == groups.count - 1 ? seg.endTime : t + totalDur * frac
					t = end
				}
				let joined = g.rows.joined(separator: " ")
				out.append(
					CaptionSegment(
						clipIndex: seg.clipIndex, clipName: seg.clipName,
						text: joined, lines: g.rows,
						startTime: start, endTime: end, wordStarts: []))
			}
		}
		return out
	}

	/// CEA-608 orphan word cascade: a 1-word, 1-line caption borrows the FIRST WORD of the
	/// following same-clip caption (just enough to no longer be a singleton). The displaced
	/// word ripples forward - the next caption may itself become a 1-word orphan, which then
	/// borrows from cap[i+2], and so on. The cascade ends at the last caption (which is
	/// allowed to be a single word - "single word at the end" is fine, mid-stream isn't).
	///
	/// Time accounting follows `wordStarts` when intact; otherwise falls back to proportional
	/// split within the donor's duration. Fully-emptied donors (orphan borrowed the donor's
	/// only word) are removed from the segment list.
	///
	/// When even ONE word from the donor would overflow `maxCharsPerLine`, we fall back to the
	/// 2-line promote (`maxLines >= 2`): make the orphan its own leading row of the next cap.
	/// If neither fits, the orphan stays.
	static func mergeOrphansCEA608(
		_ segments: [CaptionSegment], maxCharsPerLine: Int, maxLines: Int,
		maxWordsPerLine: Int
	) -> [CaptionSegment] {
		guard !segments.isEmpty else { return segments }
		var out = segments
		var i = 0
		// Orphan = 1-row cap AND (≤threshold words OR < 1.0s duration). Standard CEA-608
		// caption authoring guidance: very brief captions are hard to read AND pin the next
		// cap's pre-roll start later (visible gap). We fix both by flattening a run of
		// orphans plus their first non-orphan donor into a word stream and re-packing into
		// segments filled to the row/line budget. Per-word timing follows `wordStarts` when
		// intact, else a proportional fallback.
		//
		// The threshold is clamped to the user's `maxWordsPerLine` setting: if they ask for
		// "1 word per line", a 1-word cap IS the desired shape, not an orphan to merge.
		// Same logic for duration - only apply the readability floor when the user's word
		// setting implies they want normal-sized captions (≥3 words).
		let minDisplaySec = 1.0
		let maxOrphanWords = max(0, min(2, maxWordsPerLine - 1))
		let applyDurationCheck = maxWordsPerLine >= 3
		if maxOrphanWords == 0 && !applyDurationCheck {
			// User explicitly wants 1-word caps; nothing should be considered an orphan.
			return segments
		}
		func isOrphan(_ s: CaptionSegment) -> Bool {
			let w = s.lines.joined(separator: " ").split(separator: " ").count
			guard s.lines.count == 1 else { return false }
			if w <= maxOrphanWords { return true }
			return applyDurationCheck && (s.endTime - s.startTime) < minDisplaySec
		}
		while i < out.count {
			let cur = out[i]
			if !isOrphan(cur) {
				i += 1
				continue
			}
			// Build the run: this orphan + consecutive same-clip caps until (and including)
			// the first non-orphan donor. If we run off the end with no donor, repack what
			// we have (a clip-tail full of fragments still benefits from compaction).
			let runStart = i
			let clipIdx = cur.clipIndex
			var runEnd = i
			while runEnd + 1 < out.count, out[runEnd + 1].clipIndex == clipIdx {
				runEnd += 1
				if !isOrphan(out[runEnd]) { break }
			}
			if runEnd == runStart {
				i += 1
				continue
			}
			// Flatten the run into a word stream with per-word starts.
			var words: [String] = []
			var starts: [Double] = []
			let runEndTime = out[runEnd].endTime
			for k in runStart...runEnd {
				let s = out[k]
				let ws = s.lines.joined(separator: " ").split(separator: " ").map(String.init)
				let stz: [Double]
				if s.wordStarts.count == ws.count {
					stz = s.wordStarts
				} else {
					let segDur = s.endTime - s.startTime
					let step = ws.isEmpty ? 0 : segDur / Double(ws.count)
					stz = (0..<ws.count).map { s.startTime + step * Double($0) }
				}
				words.append(contentsOf: ws)
				starts.append(contentsOf: stz)
			}
			// Greedy pack into word ranges (start_word_idx, end_word_idx_exclusive). Track
			// ranges instead of pre-built lines so the post-pass can redistribute words
			// across the last boundary to avoid an orphan tail without re-running the
			// whole loop.
			func renderRows(_ from: Int, _ to: Int) -> [String]? {
				var rows: [String] = []
				var row = ""
				for wi in from..<to {
					let w = words[wi]
					let need = (row.isEmpty ? 0 : 1) + w.count
					if w.count > maxCharsPerLine {
						// Single word too long: hard-chunk into multiple rows.
						if !row.isEmpty {
							if rows.count >= maxLines { return nil }
							rows.append(row)
							row = ""
						}
						var chunk = w
						while !chunk.isEmpty {
							if rows.count >= maxLines { return nil }
							let take = min(maxCharsPerLine, chunk.count)
							let idx = chunk.index(chunk.startIndex, offsetBy: take)
							rows.append(String(chunk[..<idx]))
							chunk = String(chunk[idx...])
						}
						continue
					}
					if row.count + need <= maxCharsPerLine {
						row = row.isEmpty ? w : "\(row) \(w)"
					} else {
						if rows.count >= maxLines { return nil }
						rows.append(row)
						row = w
					}
				}
				if !row.isEmpty {
					if rows.count >= maxLines { return nil }
					rows.append(row)
				}
				return rows
			}
			var capRanges: [(Int, Int)] = []
			var wi = 0
			while wi < words.count {
				// Greedily find the largest range starting at wi that still fits.
				var hi = words.count
				while hi > wi, renderRows(wi, hi) == nil { hi -= 1 }
				if hi == wi { hi = wi + 1 }  // single-word fallback (hard-chunked)
				capRanges.append((wi, hi))
				wi = hi
			}
			// Redistribute the last-cap orphan tail: while the last cap is orphan AND the
			// previous cap has enough headroom, push the last word of prev into last and
			// re-render both. Stops when last is no longer orphan, or prev would itself
			// become orphan, or the new arrangement doesn't fit.
			func rangeIsOrphan(_ r: (Int, Int)) -> Bool {
				let n = r.1 - r.0
				if n <= maxOrphanWords { return true }
				if !applyDurationCheck { return false }
				let dur = (r.1 < words.count ? starts[r.1] : runEndTime) - starts[r.0]
				return dur < minDisplaySec
			}
			while capRanges.count >= 2 {
				let lastIdx = capRanges.count - 1
				let prevIdx = lastIdx - 1
				if !rangeIsOrphan(capRanges[lastIdx]) { break }
				let prev = capRanges[prevIdx]
				let last = capRanges[lastIdx]
				let prevWords = prev.1 - prev.0
				if prevWords <= maxOrphanWords + 1 { break }  // prev would become orphan
				let newPrev = (prev.0, prev.1 - 1)
				let newLast = (prev.1 - 1, last.1)
				guard renderRows(newPrev.0, newPrev.1) != nil,
					renderRows(newLast.0, newLast.1) != nil
				else { break }
				capRanges[prevIdx] = newPrev
				capRanges[lastIdx] = newLast
			}
			var packed: [CaptionSegment] = []
			for r in capRanges {
				guard let rows = renderRows(r.0, r.1) else { continue }
				let segStart = starts[r.0]
				let segEnd = r.1 < words.count ? starts[r.1] : runEndTime
				packed.append(
					CaptionSegment(
						clipIndex: clipIdx, clipName: out[runStart].clipName,
						text: rows.joined(separator: "\n"), lines: rows,
						startTime: segStart, endTime: segEnd,
						wordStarts: []))
			}
			out.replaceSubrange(runStart...runEnd, with: packed)
			i = runStart + packed.count
		}
		return out
	}

	static func splitToMaxChars(_ segments: [CaptionSegment], maxChars: Int) -> [CaptionSegment] {
		func make(_ s: CaptionSegment, _ text: String, _ start: Double, _ end: Double)
			-> CaptionSegment
		{
			CaptionSegment(
				clipIndex: s.clipIndex, clipName: s.clipName, text: text, lines: [text],
				startTime: start, endTime: end, wordStarts: [])
		}
		var out: [CaptionSegment] = []
		for seg in segments {
			let oneLine = seg.lines.joined(separator: " ")
			if oneLine.count <= maxChars {
				out.append(make(seg, oneLine, seg.startTime, seg.endTime))
				continue
			}
			let words = oneLine.split(separator: " ").map(String.init)
			var chunkTexts: [String] = []
			var chunkStartWord: [Int] = []
			var cur: [String] = []
			var curLen = 0
			var curStartWord = 0
			func flush() {
				if cur.isEmpty { return }
				chunkTexts.append(cur.joined(separator: " "))
				chunkStartWord.append(curStartWord)
				cur = []
				curLen = 0
			}
			for (wi, w) in words.enumerated() {
				if w.count > maxChars {
					flush()
					var word = w
					while !word.isEmpty {
						chunkTexts.append(String(word.prefix(maxChars)))
						chunkStartWord.append(-1)
						word = String(word.dropFirst(maxChars))
					}
					continue
				}
				let addLen = (cur.isEmpty ? 0 : 1) + w.count
				if !cur.isEmpty && curLen + addLen > maxChars { flush() }
				if cur.isEmpty {
					curStartWord = wi
					curLen = w.count
				} else {
					curLen += 1 + w.count
				}
				cur.append(w)
			}
			flush()

			let aligned = seg.wordStarts.count == words.count && !chunkStartWord.contains(-1)
			let totalDur = seg.endTime - seg.startTime
			let totalChars = chunkTexts.reduce(0) { $0 + $1.count }
			var t = seg.startTime
			for i in chunkTexts.indices {
				let start: Double
				let end: Double
				if aligned {
					start = seg.wordStarts[chunkStartWord[i]]
					end =
						i == chunkTexts.count - 1
						? seg.endTime : seg.wordStarts[chunkStartWord[i + 1]]
				} else {
					start = t
					let frac =
						totalChars > 0
						? Double(chunkTexts[i].count) / Double(totalChars)
						: 1.0 / Double(chunkTexts.count)
					end = i == chunkTexts.count - 1 ? seg.endTime : t + totalDur * frac
					t = end
				}
				out.append(make(seg, chunkTexts[i], start, end))
			}
		}
		return out
	}

	/// Augments the segment boundaries (`baseBreaks`, which already include the user's manual breaks)
	/// with the extra ≤`maxChars` word-boundary breaks CEA-608 export adds, so the editor's `|`
	/// markers match where the export actually splits. The char counter resets at every base break,
	/// so manual breaks are respected and 32-char splitting only happens within each segment.
	static func cea608BreakIndices(
		row: AudioEditRow, baseBreaks: Set<Int>, maxChars: Int
	) -> Set<Int> {
		let words = (row.editedWords ?? row.words).map {
			$0.word.trimmingCharacters(in: .whitespaces)
		}
		guard words.count > 1 else { return baseBreaks }
		var breaks = baseBreaks
		var curLen = 0
		for (i, w) in words.enumerated() {
			if i == 0 {
				curLen = w.count
				continue
			}
			if baseBreaks.contains(i) {
				curLen = w.count
				continue
			}
			let addLen = 1 + w.count
			if curLen + addLen > maxChars {
				breaks.insert(i)
				curLen = w.count
			} else {
				curLen += addLen
			}
		}
		return breaks
	}

	/// Forces same-clip captions to be sequential by TRIMMING the earlier one's end down to the
	/// later one's start when they overlap (start times stay anchored to speech timing). Captions
	/// from different clips are left untouched so cross-clip overlap (intentional, e.g. simultaneous
	/// speakers across two audio clips) is preserved.
	static func enforceSequentialPerClip(_ segments: [CaptionSegment]) -> [CaptionSegment] {
		guard segments.count > 1 else { return segments }
		var result = segments
		let groups = Dictionary(grouping: result.indices, by: { result[$0].clipIndex })
		for (_, idxs) in groups {
			let sorted = idxs.sorted { result[$0].startTime < result[$1].startTime }
			for k in 0..<(sorted.count - 1) {
				let i = sorted[k]
				let j = sorted[k + 1]
				if result[i].endTime > result[j].startTime {
					let seg = result[i]
					result[i] = CaptionSegment(
						clipIndex: seg.clipIndex, clipName: seg.clipName, text: seg.text,
						lines: seg.lines, startTime: seg.startTime,
						endTime: max(seg.startTime, result[j].startTime),
						wordStarts: seg.wordStarts)
				}
			}
		}
		return result
	}

	static func hasOverlaps(_ segments: [CaptionSegment]) -> Bool {
		let sorted = segments.sorted { $0.startTime < $1.startTime }
		let epsilon = 0.001
		var maxEnd = -Double.infinity
		for seg in sorted {
			if seg.startTime < maxEnd - epsilon { return true }
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
		let wordStartIndex: Int
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

			// Step 2: Find break point - forced breaks take priority
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
						wordStarts: segmentWordStarts,
						wordStartIndex: segStart
					))
			}

			i = segEnd
		}

		return groups
	}

	static func predictedBreakIndices(
		row: AudioEditRow,
		style: CaptionStyleSettings,
		textStyle: TextStyleSettings,
		exportWidth: Int,
		exportHeight: Int,
		language: String?
	) -> Set<Int> {
		let words = row.editedWords ?? row.words
		guard words.count > 1 else { return [] }

		let fcpFontSize = textStyle.textSize * Double(exportHeight) / 1080.0
		let font =
			NSFont(name: textStyle.textFont, size: CGFloat(fcpFontSize))
			?? NSFont.systemFont(ofSize: CGFloat(fcpFontSize))
		let availableWidth = Double(exportWidth) * textStyle.textWidthPercent / 100.0

		let processedWords = words.map { word in
			processWord(word.word, style: style, language: language)
		}

		let lineGroups = splitIntoLines(
			words: processedWords,
			timings: words,
			style: style,
			font: font,
			availableWidth: availableWidth,
			forcedBreaks: Set(row.captionBreaks)
		)

		var merged: [LineGroup] = []
		var j = 0
		while j < lineGroups.count {
			var group = lineGroups[j]
			var duration = group.endTime - group.startTime
			while duration < Float(minimumDuration),
				j + 1 < lineGroups.count,
				lineGroups[j + 1].startTime - group.endTime < Float(gapCloseThreshold)
			{
				let next = lineGroups[j + 1]
				group = LineGroup(
					lines: group.lines,
					startTime: group.startTime,
					endTime: next.endTime,
					wordStarts: group.wordStarts + next.wordStarts,
					wordStartIndex: group.wordStartIndex
				)
				j += 1
				duration = group.endTime - group.startTime
			}
			merged.append(group)
			j += 1
		}

		var breakIndices = Set<Int>()
		for i in 1..<merged.count {
			breakIndices.insert(merged[i].wordStartIndex)
		}
		return breakIndices
	}
}
