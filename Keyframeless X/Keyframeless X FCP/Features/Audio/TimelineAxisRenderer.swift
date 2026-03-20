/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit

struct TimelineAxisRenderer {
	let bounds: CGRect
	let duration: Double
	let clips: [FCPXMLParser.AudioClip]
	let selectedClips: Set<Int>
	let visibleIndices: Set<Int>?
	let dimmedIndices: Set<Int>
	let showWaveforms: Bool
	let hoveredClipIndex: Int?
	let pulsePhase: CGFloat
	let waveforms: [Int: [Float]]
	let hasAudioPlayer: Bool
	let playingIndex: Int?
	let currentTime: Double?
	let labelForTime: ((Double) -> String)?

	let playBtnSize: CGFloat = 12
	let minHeightForControls: CGFloat = 16
	let scrubStripHeight: CGFloat = 14

	func draw(in ctx: CGContext, cachedClipRects: inout [(rect: CGRect, index: Int)]) {
		guard duration > 0 else { return }

		let pps = bounds.width / CGFloat(max(1, duration))
		let emptyX = CGFloat(duration) * pps

		drawEmptyRegion(in: ctx, pps: pps, emptyX: emptyX)
		drawTickMarks(in: ctx, pps: pps)
		drawClips(in: ctx, pps: pps, emptyX: emptyX, cachedClipRects: &cachedClipRects)
	}

	private func drawEmptyRegion(in ctx: CGContext, pps: CGFloat, emptyX: CGFloat) {
		let emptyFillTop: CGFloat = 5 + 12 + 6
		let emptyFillBottom: CGFloat = bounds.height - 4
		ctx.setFillColor(NSColor.black.withAlphaComponent(0.15).cgColor)
		ctx.fill(
			CGRect(
				x: emptyX, y: emptyFillTop, width: bounds.width - emptyX,
				height: emptyFillBottom - emptyFillTop))
	}

	private func drawTickMarks(in ctx: CGContext, pps: CGFloat) {
		let baseline: CGFloat = 5
		let tickHeight: CGFloat = 12
		let strokeWidth: CGFloat = 1.0
		let interval = tickInterval(pixelsPerSecond: pps)

		let attrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.boldSystemFont(ofSize: 10),
			.foregroundColor: NSColor.timelineLabel()!,
		]

		ctx.setLineWidth(strokeWidth)
		ctx.setStrokeColor(NSColor.timelineTick().cgColor)
		ctx.beginPath()

		var t = 0.0
		while t <= duration + 0.001 {
			let rawX = CGFloat(t) * pps
			let x = max(strokeWidth / 2, rawX)

			ctx.move(to: CGPoint(x: x, y: baseline))
			ctx.addLine(to: CGPoint(x: x, y: baseline + tickHeight))

			let label = labelForTime?(t) ?? String(format: "%.0fs", t)
			let labelSize = (label as NSString).size(withAttributes: attrs)
			let labelY = baseline + (tickHeight - labelSize.height) / 2
			if x + 5 + labelSize.width <= bounds.width {
				(label as NSString).draw(at: CGPoint(x: x + 5, y: labelY), withAttributes: attrs)
			}

			t += interval
		}

		ctx.strokePath()
	}

	private func drawClips(
		in ctx: CGContext, pps: CGFloat, emptyX: CGFloat,
		cachedClipRects: inout [(rect: CGRect, index: Int)]
	) {
		guard !clips.isEmpty else { return }

		let baseline: CGFloat = 5
		let tickHeight: CGFloat = 12
		let laneGap: CGFloat = 4
		let clipAreaTop: CGFloat = baseline + tickHeight + 6
		let clipAreaHeight = bounds.height - clipAreaTop - 4
		let assignments = laneAssignments(for: clips)
		let numLanes = CGFloat((assignments.max() ?? 0) + 1)
		let laneHeight = max(4, (clipAreaHeight - laneGap * (numLanes - 1)) / numLanes)
		let cornerRadius: CGFloat = 6

		cachedClipRects = []
		for (i, clip) in clips.enumerated() {
			if let visible = visibleIndices, !visible.contains(i) { continue }
			let lane = CGFloat(assignments[i])
			let x = CGFloat(clip.start) * pps
			let w = min(max(cornerRadius * 2, CGFloat(clip.end - clip.start) * pps), emptyX - x)
			let y = clipAreaTop + lane * (laneHeight + laneGap)
			let rect = CGRect(x: x, y: y, width: w, height: laneHeight)
			cachedClipRects.append((rect: rect, index: i))

			let clipState = ClipDrawState(
				index: i, clip: clip, rect: rect, cornerRadius: cornerRadius,
				laneHeight: laneHeight, w: w)
			drawClipBackground(clipState, in: ctx)
			drawClipContent(clipState, in: ctx)
		}
	}

	private struct ClipDrawState {
		let index: Int
		let clip: FCPXMLParser.AudioClip
		let rect: CGRect
		let cornerRadius: CGFloat
		let laneHeight: CGFloat
		let w: CGFloat
	}

	private func drawClipBackground(_ state: ClipDrawState, in ctx: CGContext) {
		let isDimmed = dimmedIndices.contains(state.index)
		let isHoverDimmed = hoveredClipIndex != nil && hoveredClipIndex != state.index && !isDimmed
		let alpha: CGFloat =
			isDimmed
			? 0.1 : isHoverDimmed ? 0.25 : selectedClips.contains(state.index) ? 0.85 : 0.25
		let clipColor = clipColor(for: state.clip, isDimmed: isDimmed)

		ctx.setFillColor(clipColor.withAlphaComponent(alpha).cgColor)
		let path = CGPath(
			roundedRect: state.rect, cornerWidth: state.cornerRadius,
			cornerHeight: state.cornerRadius, transform: nil)
		ctx.addPath(path)
		ctx.fillPath()

		if isDimmed && hoveredClipIndex == state.index {
			drawPulseGlow(rect: state.rect, path: path, color: clipColor, dimmed: true, in: ctx)
		}

		if !isDimmed && !isHoverDimmed && hoveredClipIndex == state.index {
			drawPulseGlow(rect: state.rect, path: path, color: clipColor, dimmed: false, in: ctx)
		}
	}

	private func drawPulseGlow(
		rect: CGRect, path: CGPath, color: NSColor, dimmed: Bool, in ctx: CGContext
	) {
		let pulse = 0.7 + 0.3 * sin(pulsePhase * 2.0 * .pi / 2.0)
		ctx.saveGState()
		ctx.clip(to: rect.insetBy(dx: -3, dy: -3))
		ctx.setShadow(
			offset: .zero, blur: 4,
			color: color.withAlphaComponent(dimmed ? pulse * 0.4 : pulse).cgColor)
		ctx.setFillColor(color.withAlphaComponent(dimmed ? pulse * 0.2 : pulse).cgColor)
		ctx.addPath(path)
		ctx.fillPath()
		ctx.restoreGState()

		if !dimmed {
			ctx.setFillColor(color.withAlphaComponent(pulse * 0.5).cgColor)
			ctx.addPath(path)
			ctx.fillPath()
		}
	}

	private func drawClipContent(_ state: ClipDrawState, in ctx: CGContext) {
		let isDimmed = dimmedIndices.contains(state.index)
		let isHoverDimmed = hoveredClipIndex != nil && hoveredClipIndex != state.index && !isDimmed
		if isDimmed || isHoverDimmed { return }

		let hasAudioControls =
			hasAudioPlayer
			&& state.laneHeight >= minHeightForControls
			&& state.w > playBtnSize + 8
			&& state.clip.url != nil

		if showWaveforms, let samples = waveforms[state.index], !samples.isEmpty {
			drawClipWaveform(
				samples, state: state, hasAudioControls: hasAudioControls, in: ctx)
		}

		if hasAudioControls {
			drawAudioControls(state, in: ctx)
		} else if state.laneHeight >= 16 && state.w > 30 {
			drawClipTitle(state, in: ctx)
		}
	}

	private func drawClipWaveform(
		_ samples: [Float], state: ClipDrawState, hasAudioControls: Bool, in ctx: CGContext
	) {
		if hasAudioControls {
			let titleStripH: CGFloat = playBtnSize + 8
			let waveformY = state.rect.minY + titleStripH
			let waveformH = state.rect.height - titleStripH - scrubStripHeight
			if waveformH > 4 {
				drawWaveform(
					samples,
					in: CGRect(
						x: state.rect.minX, y: waveformY,
						width: state.rect.width, height: waveformH),
					context: ctx, selected: selectedClips.contains(state.index))
			}
		} else {
			drawWaveform(
				samples, in: state.rect, context: ctx,
				selected: selectedClips.contains(state.index))
		}
	}

	private func drawAudioControls(_ state: ClipDrawState, in ctx: CGContext) {
		let isPlaying = playingIndex == state.index
		let playBtnRect = CGRect(
			x: state.rect.minX + 4, y: state.rect.minY + 4,
			width: playBtnSize, height: playBtnSize)
		drawPlayButton(in: playBtnRect, context: ctx, isPlaying: isPlaying)

		let titleX = state.rect.minX + 4 + playBtnSize + 10
		let titleW = state.rect.maxX - titleX - 6
		if titleW > 10 {
			drawInlineTitle(
				state.clip.name, x: titleX, width: titleW,
				centerY: state.rect.minY + 4 + playBtnSize / 2 + 2,
				alpha: 0.85, in: ctx)
		}

		var progress: Double?
		if isPlaying, let ct = currentTime {
			let offset = ct - state.clip.sourceStart
			progress = max(0, min(1, offset / state.clip.sourceDuration))
		}
		drawScrubBar(in: state.rect, context: ctx, progress: progress)
	}

	private func drawClipTitle(_ state: ClipDrawState, in ctx: CGContext) {
		let isSelected = selectedClips.contains(state.index)
		let para = NSMutableParagraphStyle()
		para.lineBreakMode = .byTruncatingTail
		let titleAttrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 10, weight: .medium),
			.foregroundColor: NSColor.white.withAlphaComponent(isSelected ? 0.85 : 0.5),
			.paragraphStyle: para,
		]
		let titleStr = state.clip.name as NSString
		let titleH = titleStr.size(withAttributes: titleAttrs).height
		let titleRect = CGRect(
			x: state.rect.minX + 6, y: state.rect.midY - titleH / 2,
			width: state.rect.width - 12, height: titleH)
		titleStr.draw(
			with: titleRect, options: .usesLineFragmentOrigin,
			attributes: titleAttrs, context: nil)
	}

	private func drawInlineTitle(
		_ name: String, x: CGFloat, width: CGFloat, centerY: CGFloat,
		alpha: CGFloat, in ctx: CGContext
	) {
		let para = NSMutableParagraphStyle()
		para.lineBreakMode = .byTruncatingTail
		let titleAttrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 10, weight: .medium),
			.foregroundColor: NSColor.white.withAlphaComponent(alpha),
			.paragraphStyle: para,
		]
		let titleStr = name as NSString
		let titleH = titleStr.size(withAttributes: titleAttrs).height
		let titleY = centerY - titleH / 2
		let titleRect = CGRect(x: x, y: titleY, width: width, height: titleH)
		titleStr.draw(
			with: titleRect, options: .usesLineFragmentOrigin, attributes: titleAttrs,
			context: nil)
	}

	func drawPlayButton(in rect: CGRect, context ctx: CGContext, isPlaying: Bool) {
		let padding: CGFloat = 2
		let cx = rect.minX + rect.width / 2 + padding
		let cy = rect.midY + padding
		let r = rect.height / 2 + 2

		let circleRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
		ctx.saveGState()
		ctx.setShadow(offset: .zero, blur: 8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
		ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
		ctx.fillEllipse(in: circleRect)
		ctx.restoreGState()

		let symbolName = isPlaying ? "pause.fill" : "play.fill"
		let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.6, weight: .regular)
		guard
			let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
				.withSymbolConfiguration(config)
		else { return }
		image.lockFocus()
		NSColor.white.withAlphaComponent(0.9).set()
		NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
		image.unlockFocus()

		let imgSize = image.size
		let imgRect = CGRect(
			x: cx - imgSize.width / 2 + 0.5,
			y: cy - imgSize.height / 2,
			width: imgSize.width,
			height: imgSize.height)
		image.draw(in: imgRect)
	}

	func drawScrubBar(in rect: CGRect, context ctx: CGContext, progress: Double?) {
		let trackH: CGFloat = 3
		let trackX = rect.minX
		let trackW = rect.width
		guard trackW > 0 else { return }
		let trackY = rect.maxY - trackH - 5

		ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
		let trackPath = CGPath(
			roundedRect: CGRect(x: trackX, y: trackY, width: trackW, height: trackH),
			cornerWidth: trackH / 2, cornerHeight: trackH / 2, transform: nil)
		ctx.addPath(trackPath)
		ctx.fillPath()

		guard let progress else { return }

		let fillW = trackW * CGFloat(progress)
		if fillW > 0 {
			ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
			let fillPath = CGPath(
				roundedRect: CGRect(x: trackX, y: trackY, width: fillW, height: trackH),
				cornerWidth: trackH / 2, cornerHeight: trackH / 2, transform: nil)
			ctx.addPath(fillPath)
			ctx.fillPath()
		}

		let knobR: CGFloat = 4.5
		let knobX = trackX + fillW
		ctx.setFillColor(NSColor.white.cgColor)
		ctx.fillEllipse(
			in: CGRect(
				x: knobX - knobR, y: trackY + trackH / 2 - knobR,
				width: knobR * 2, height: knobR * 2))
	}

	func drawWaveform(
		_ samples: [Float], in rect: CGRect, context ctx: CGContext, selected: Bool
	) {
		let alpha: CGFloat = selected ? 0.7 : 0.35
		ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)

		let barCount = max(1, Int(rect.width / 2))
		let barWidth = rect.width / CGFloat(barCount)
		let midY = rect.midY
		let halfH = rect.height * 0.35

		let peak = samples.max() ?? 1
		let scale = peak > 0 ? 1 / CGFloat(peak) : 1

		ctx.setLineWidth(max(1, barWidth * 0.75))
		ctx.beginPath()
		for b in 0..<barCount {
			let sampleIndex = min(
				Int(Double(b) * Double(samples.count) / Double(barCount)), samples.count - 1)
			let amp = CGFloat(samples[sampleIndex]) * scale
			let sx = rect.minX + (CGFloat(b) + 0.5) * barWidth
			let h = max(1, amp * halfH)
			ctx.move(to: CGPoint(x: sx, y: midY - h))
			ctx.addLine(to: CGPoint(x: sx, y: midY + h))
		}
		ctx.strokePath()
	}

	private func clipColor(for clip: FCPXMLParser.AudioClip, isDimmed: Bool) -> NSColor {
		isDimmed
			? NSColor.secondaryLabelColor
			: clip.isCompound
				? NSColor.warning() ?? NSColor.yellow : NSColor.accent() ?? NSColor.blue
	}

	private func laneAssignments(for clips: [FCPXMLParser.AudioClip]) -> [Int] {
		var result = [Int](repeating: 0, count: clips.count)
		var laneEnds = [Double]()
		for (origIdx, clip) in clips.enumerated().sorted(by: { $0.element.start < $1.element.start }
		) {
			if let lane = laneEnds.firstIndex(where: { $0 <= clip.start }) {
				result[origIdx] = lane
				laneEnds[lane] = clip.end
			} else {
				result[origIdx] = laneEnds.count
				laneEnds.append(clip.end)
			}
		}
		return result
	}

	private func tickInterval(pixelsPerSecond: CGFloat) -> Double {
		let minSpacing: CGFloat = 70
		let candidates = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600]
		return candidates.first { CGFloat($0) * pixelsPerSecond >= minSpacing } ?? 600
	}
}
