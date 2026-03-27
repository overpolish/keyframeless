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
	let overlapRegions: [CaptionBuilder.OverlapRegion]
	let showWaveforms: Bool
	let hoveredClipIndex: Int?
	let glowClipIndex: Int?
	let pulsePhase: CGFloat
	let waveforms: [Int: [Float]]
	let hasAudioPlayer: Bool
	let playingIndex: Int?
	let labelForTime: ((Double) -> String)?
	var skipWaveforms: Bool = false
	var dirtyRect: CGRect = .null

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
		drawOverlapRegions(in: ctx, pps: pps)
	}

	private func drawOverlapRegions(in ctx: CGContext, pps: CGFloat) {
		guard !overlapRegions.isEmpty else { return }
		let top: CGFloat = 5 + 12 + 6
		let height = bounds.height - top - 4
		let stripeColor = NSColor.error().withAlphaComponent(0.25)
		let stripeWidth: CGFloat = 6
		let stripeSpacing: CGFloat = 3

		for region in overlapRegions {
			let x = CGFloat(region.start) * pps
			let w = CGFloat(region.end - region.start) * pps
			let rect = CGRect(x: x, y: top, width: max(2, w), height: height)

			ctx.saveGState()
			ctx.clip(to: rect)
			ctx.setFillColor(stripeColor.cgColor)

			let stride = stripeWidth + stripeSpacing
			let diagonal = w + height
			var offset: CGFloat = -height

			while offset < diagonal {
				ctx.move(to: CGPoint(x: x + offset, y: top + height))
				ctx.addLine(to: CGPoint(x: x + offset + stripeWidth, y: top + height))
				ctx.addLine(to: CGPoint(x: x + offset + height + stripeWidth, y: top))
				ctx.addLine(to: CGPoint(x: x + offset + height, y: top))
				ctx.closePath()
				offset += stride
			}
			ctx.fillPath()
			ctx.restoreGState()
		}
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

		if isDimmed && glowClipIndex == state.index {
			drawPulseGlow(rect: state.rect, path: path, color: clipColor, dimmed: true, in: ctx)
		}

		if !isDimmed && !isHoverDimmed && glowClipIndex == state.index {
			let isSelected = selectedClips.contains(state.index)
			drawPulseGlow(
				rect: state.rect, path: path, color: clipColor, dimmed: !isSelected, in: ctx)
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

		if showWaveforms, !skipWaveforms, let samples = waveforms[state.index], !samples.isEmpty {
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

		drawScrubBar(in: state.rect, context: ctx)
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

	func drawScrubBar(in rect: CGRect, context ctx: CGContext) {
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
	}

	func drawWaveform(
		_ samples: [Float], in rect: CGRect, context ctx: CGContext, selected: Bool
	) {
		let alpha: CGFloat = selected ? 0.7 : 0.35
		let midY = rect.midY
		let halfH = rect.height * 0.4

		let peak = samples.max() ?? 1
		let scale = peak > 0 ? 1 / CGFloat(peak) : 1

		// Only draw the visible portion of the waveform
		let visX = dirtyRect.isNull ? rect : rect.intersection(dirtyRect)
		guard !visX.isEmpty else { return }
		let drawStart = max(0, Int(visX.minX - rect.minX) - 1)
		let drawEnd = min(Int(rect.width), Int(visX.maxX - rect.minX) + 1)
		let drawCount = drawEnd - drawStart
		guard drawCount > 0 else { return }

		// Map buckets to visible pixels using max of all buckets per pixel
		let totalPoints = max(1, Int(rect.width))
		let ratio = Double(samples.count) / Double(totalPoints)
		var pixelAmps = [CGFloat](repeating: 0, count: drawCount)
		for i in 0..<drawCount {
			let pi = drawStart + i
			let lo = Int(Double(pi) * ratio)
			let hi = min(Int(Double(pi + 1) * ratio), samples.count)
			var maxVal: Float = 0
			for j in lo..<hi { maxVal = max(maxVal, samples[j]) }
			pixelAmps[i] = CGFloat(maxVal) * scale
		}

		// Build filled envelope path: top edge forward, bottom edge backward
		ctx.beginPath()
		for i in 0..<drawCount {
			let x = rect.minX + CGFloat(drawStart + i)
			let h = pixelAmps[i] * halfH
			let pt = CGPoint(x: x, y: midY - h)
			if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
		}
		for i in stride(from: drawCount - 1, through: 0, by: -1) {
			let x = rect.minX + CGFloat(drawStart + i)
			let h = pixelAmps[i] * halfH
			ctx.addLine(to: CGPoint(x: x, y: midY + h))
		}
		ctx.closePath()
		ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
		ctx.fillPath()
	}

	private func clipColor(for clip: FCPXMLParser.AudioClip, isDimmed: Bool) -> NSColor {
		isDimmed
			? NSColor.secondaryLabelColor
			: clip.isCompound
				? NSColor.controlAccentColor.compound() : NSColor.controlAccentColor
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
