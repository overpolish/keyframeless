/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import CoreMedia
import Foundation

/// Adjusts caption timing so a CEA-608 conversion validates cleanly. FCP delegates SCC validation
/// to AVFoundation's AVCaptionConversionValidator (FFSCCCaptionValidator instantiates the same
/// class via NSClassFromString with conversionSettings {mediaType:closedCaption, mediaSubType:'c608'}),
/// so we use it directly to get the exact frame-spacing/start-offset adjustments FCP would otherwise
/// flag as errors ("too close to previous caption", "too close to project start"). Returned
/// AVCaptionConversionTimeRangeAdjustment.startTimeOffset/durationOffset are applied to the matching
/// segments, then re-validated; iterates until clean or no further changes.
enum CEA608TimingValidator {
	private static let maxIterations = 10

	/// Parses an FCPXML-style frameDuration like "1001/30000s" or "1/30s" into (num, den).
	/// Frame N in seconds = N * num / den; CMTime at scale=den has integer value frame*num.
	private static func parseFrameDuration(_ s: String) -> (num: Int32, den: Int32) {
		let raw = s.hasSuffix("s") ? String(s.dropLast()) : s
		guard let slash = raw.firstIndex(of: "/") else { return (1, 30) }
		let num = Int32(Double(raw[raw.startIndex..<slash]) ?? 1)
		let den = Int32(Double(raw[raw.index(after: slash)...]) ?? 30)
		return (max(1, num), max(1, den))
	}

	static func adjusted(_ segments: [CaptionSegment], frameDuration: String) -> [CaptionSegment] {
		guard !segments.isEmpty else { return segments }
		guard #available(macOS 12.0, *) else { return segments }

		let fr = parseFrameDuration(frameDuration)
		let minDuration = Double(fr.num) / Double(fr.den)  // 1 frame
		var current = segments

		// Alternate same-clip trim and validator until both are satisfied. The trim alone can
		// recreate a too-tight SCC gap (validator just pushed A later, trim then shortens A's end
		// to B's start) and the validator alone can push one caption without its neighbour, so we
		// run both each iteration until the validator returns no warnings.
		for _ in 0..<maxIterations {
			current = CaptionBuilder.enforceSequentialPerClip(current)
			let (warnings, captionToSeg) = validate(captions: current, frameRate: fr)
			if warnings.isEmpty { break }
			var starts = current.map(\.startTime)
			var ends = current.map(\.endTime)
			var changed = false
			for w in warnings {
				guard let adj = w.adjustment as? AVCaptionConversionTimeRangeAdjustment else {
					continue
				}
				let startOff = CMTimeGetSeconds(adj.startTimeOffset)
				let durOff = CMTimeGetSeconds(adj.durationOffset)
				if startOff == 0 && durOff == 0 { continue }
				// rangeOfCaptions indexes the flat (per-row-expanded) caption list AVF saw, not
				// our source segments. Map back via captionToSeg, dedupe so each source segment
				// gets one adjustment per warning (worst-case wins via the max() folding).
				let flatLower = max(0, w.rangeOfCaptions.location)
				let flatUpper = min(captionToSeg.count, flatLower + w.rangeOfCaptions.length)
				var segIdxs = Set<Int>()
				for k in flatLower..<flatUpper { segIdxs.insert(captionToSeg[k]) }
				for i in segIdxs.sorted() {
					guard i < current.count else { continue }
					// Apply with PRESERVE-END semantics: push only the start, keep the original
					// end. The caption shrinks but its end frame is unchanged, so the next
					// caption's required spacing window is unaffected and timing doesn't cascade.
					// durOff (validator asking for more duration) extends the end.
					let newStart = max(0, starts[i] + startOff)
					let proposedEnd = ends[i] + durOff
					let newEnd = max(newStart + minDuration, proposedEnd)
					if newStart != starts[i] || newEnd != ends[i] {
						starts[i] = newStart
						ends[i] = newEnd
						changed = true
					}
				}
			}
			if !changed { break }
			current = current.enumerated().map { (i, seg) in
				CaptionSegment(
					clipIndex: seg.clipIndex, clipName: seg.clipName, text: seg.text,
					lines: seg.lines, startTime: starts[i], endTime: ends[i],
					wordStarts: seg.wordStarts)
			}
		}
		// FCP's import-side validator is stricter than AVCaptionConversionValidator for the
		// first caption when it's multi-row: AVF says "no warnings" but FCP demands ~6 more
		// frames of pre-roll per extra row (positioning-code bytes AVF doesn't account for).
		// Apply an empirical post-pass for the first caption only - in-between captions get
		// their per-row cost through normal validator warnings since the windows are longer.
		if let first = current.first {
			let extraRows = max(1, first.lines.count) - 1
			if extraRows > 0 {
				let extraSec = Double(extraRows * 6) * Double(fr.num) / Double(fr.den)
				let newStart = first.startTime + extraSec
				let newEnd = max(newStart + minDuration, first.endTime)
				current[0] = CaptionSegment(
					clipIndex: first.clipIndex, clipName: first.clipName, text: first.text,
					lines: first.lines, startTime: newStart, endTime: newEnd,
					wordStarts: first.wordStarts)
			}
		}
		// If we hit maxIterations the last action was an apply (may have created overlap); final
		// trim guarantees a same-clip-sequential output regardless of validator convergence.
		return CaptionBuilder.enforceSequentialPerClip(current)
	}

	@available(macOS 12.0, *)
	private static func validate(
		captions: [CaptionSegment], frameRate: (num: Int32, den: Int32)
	) -> (warnings: [AVCaptionConversionWarning], captionToSeg: [Int]) {
		// Quantize each caption time to the PROJECT frame grid (CMTime value = frame * num,
		// timescale = den). FCP's PCCaption → AVCaption conversion happens in this domain, so
		// AVF inside FCP sees frame-aligned times. With an arbitrary 30000 timescale our
		// validator would see slightly different times for non-30 fps projects (29.97, 23.976,
		// 25) and miss warnings that FCP's AVF reports.
		func quantize(_ s: Double) -> CMTime {
			let frame = Int64((s * Double(frameRate.den) / Double(frameRate.num)).rounded())
			return CMTime(value: frame * Int64(frameRate.num), timescale: frameRate.den)
		}
		// Multi-row CEA-608 fans into N PCs at paste-time (one per grid row); each row's
		// positioning codes cost additional SCC bytes which AVF accounts for in its pre-roll
		// math. Pass joined-text as one AVCaption and AVF underestimates byte cost (single
		// row), so our pre-pass green-lights what FCP's import-time validator then rejects
		// ("caption occurred too close to beginning of timeline, should be N frames later").
		// Emit one AVCaption per row at the segment's timeRange so AVF sees the true
		// per-row cost; warning indices still map to the source segment via the parallel
		// `captionToSeg` table.
		var caps: [AVCaption] = []
		var captionToSeg: [Int] = []
		for (i, seg) in captions.enumerated() {
			let rows = seg.lines.isEmpty ? [seg.text] : seg.lines
			let tr = CMTimeRange(start: quantize(seg.startTime), end: quantize(seg.endTime))
			for row in rows {
				caps.append(AVMutableCaption(row, timeRange: tr))
				captionToSeg.append(i)
			}
		}
		let settings: [AVCaptionSettingsKey: Any] = [
			.mediaType: AVMediaType.closedCaption.rawValue,
			.mediaSubType: NSNumber(value: Int(kCMClosedCaptionFormatType_CEA608)),
		]
		// Use a FINITE timeRange ending past the last caption. AVF's header says comprehensive
		// validation requires a definite duration; with +∞ some checks may be skipped.
		let lastEnd = captions.map(\.endTime).max() ?? 0
		let trange = CMTimeRange(start: .zero, duration: quantize(lastEnd + 1.0))
		let validator = AVCaptionConversionValidator(
			captions: caps, timeRange: trange, conversionSettings: settings)
		let sema = DispatchSemaphore(value: 0)
		validator.validateCaptionConversion { warning in
			if warning == nil { sema.signal() }
		}
		sema.wait()
		return (validator.warnings, captionToSeg)
	}
}
