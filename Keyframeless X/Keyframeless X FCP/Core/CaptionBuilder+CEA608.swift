/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import Foundation

// CEA-608-specific segment splitting: the multi-row grid splitter and the
// orphan-merge pass. Lives apart from the core builder because it is the
// fiddliest, most format-specific part of the pipeline. Callers reach these
// the same way (CaptionBuilder.splitCEA608Multiline / .mergeOrphansCEA608).
extension CaptionBuilder {

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
}
