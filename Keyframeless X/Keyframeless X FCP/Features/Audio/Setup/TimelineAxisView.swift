/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import KeyframelessKit
import SwiftUI

struct TimelineAxisView: View {
	let duration: Double
	let format: FCPXMLParser.ProjectFormat?
	let useTimecode: Bool
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>
	@ObservedObject var audioPlayer: AudioPlayer

	@State private var zoom: CGFloat = 1.0

	var body: some View {
		GeometryReader { geo in
			TimelineAxisScrollView(
				duration: duration,
				clips: clips,
				selectedClips: $selectedClips,
				zoom: $zoom,
				availableWidth: geo.size.width,
				availableHeight: geo.size.height,
				labelForTime: labelForTime,
				audioPlayer: audioPlayer
			)
		}
	}

	private func labelForTime(_ time: Double) -> String {
		let h = Int(time) / 3600
		let m = Int(time) % 3600 / 60
		let s = Int(time) % 60
		return String(format: "%02d:%02d:%02d", h, m, s)
	}
}

private struct TimelineAxisScrollView: NSViewRepresentable {
	let duration: Double
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>
	@Binding var zoom: CGFloat
	let availableWidth: CGFloat
	let availableHeight: CGFloat
	let labelForTime: (Double) -> String
	@ObservedObject var audioPlayer: AudioPlayer

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> NSScrollView {
		let scrollView = NSScrollView()
		scrollView.hasHorizontalScroller = false
		scrollView.hasVerticalScroller = false
		scrollView.drawsBackground = false
		scrollView.horizontalScrollElasticity = .allowed

		let docView = AxisDocumentView()
		docView.onMagnify = { delta, mouseX in
			context.coordinator.handleMagnify(delta: delta, mouseX: mouseX, scrollView: scrollView)
		}
		scrollView.documentView = docView
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		context.coordinator.binding = $zoom
		context.coordinator.zoom = zoom
		context.coordinator.availableWidth = availableWidth

		guard let docView = scrollView.documentView as? AxisDocumentView else { return }
		let contentWidth = max(availableWidth, availableWidth * zoom)
		let docHeight = availableHeight > 0 ? availableHeight : 36
		docView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: docHeight)
		docView.duration = duration
		docView.clips = clips
		docView.selectedClips = selectedClips
		docView.audioPlayer = audioPlayer
		docView.onToggleClip = { index in
			if selectedClips.contains(index) {
				selectedClips.remove(index)
			} else {
				selectedClips.insert(index)
			}
		}
		docView.labelForTime = labelForTime
		docView.needsDisplay = true
	}

	class Coordinator {
		var binding: Binding<CGFloat>?
		var zoom: CGFloat = 1.0
		var availableWidth: CGFloat = 0

		func handleMagnify(delta: CGFloat, mouseX: CGFloat, scrollView: NSScrollView) {
			let oldZoom = zoom
			zoom = max(1, min(500, zoom * delta))
			binding?.wrappedValue = zoom

			// mouseX is already in document/content coordinates — do not add scrollOffset
			let scrollOffset = scrollView.documentVisibleRect.origin.x
			let oldContentWidth = availableWidth * oldZoom
			let newContentWidth = availableWidth * zoom
			let newContentX = (mouseX / oldContentWidth) * newContentWidth
			let visibleMouseX = mouseX - scrollOffset
			let newScrollOffset = newContentX - visibleMouseX
			let maxOffset = newContentWidth - availableWidth
			scrollView.documentView?.scroll(
				NSPoint(x: max(0, min(maxOffset, newScrollOffset)), y: 0))
		}
	}
}

private class AxisDocumentView: NSView {
	var duration: Double = 0
	var clips: [FCPXMLParser.AudioClip] = [] {
		didSet { loadWaveformsIfNeeded(from: oldValue) }
	}
	var selectedClips: Set<Int> = []
	var onToggleClip: ((Int) -> Void)?
	var labelForTime: ((Double) -> String)?
	var onMagnify: ((CGFloat, CGFloat) -> Void)?
	var audioPlayer: AudioPlayer? {
		didSet {
			cancellables = []
			audioPlayer?.objectWillChange
				.receive(on: RunLoop.main)
				.sink { [weak self] _ in self?.needsDisplay = true }
				.store(in: &cancellables)
		}
	}

	private var cachedClipRects: [(rect: CGRect, index: Int)] = []
	private var waveforms: [Int: [Float]] = [:]
	private var waveformTasks: [Int: Task<Void, Never>] = [:]
	private var cancellables: Set<AnyCancellable> = []
	private var scrubbingClipIndex: Int?
	private var isDraggingSelection = false
	private var dragHoveredIndex: Int?

	private let playBtnSize: CGFloat = 12
	private let minHeightForControls: CGFloat = 16
	private let scrubStripHeight: CGFloat = 14

	override var isFlipped: Bool { true }

	private func loadWaveformsIfNeeded(from oldClips: [FCPXMLParser.AudioClip]) {
		let urlsChanged = clips.map(\.url) != oldClips.map(\.url)
		if urlsChanged {
			waveformTasks.values.forEach { $0.cancel() }
			waveformTasks = [:]
			waveforms = [:]
		}
		for (i, clip) in clips.enumerated() {
			guard waveforms[i] == nil, waveformTasks[i] == nil else { continue }
			waveformTasks[i] = Task {
				guard let samples = try? await WaveformLoader.shared.waveform(for: clip) else {
					return
				}
				await MainActor.run { [weak self] in
					self?.waveforms[i] = samples
					self?.needsDisplay = true
				}
			}
		}
	}

	override func magnify(with event: NSEvent) {
		let mouseX = convert(event.locationInWindow, from: nil).x
		onMagnify?(1 + event.magnification, mouseX)
	}

	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		for entry in cachedClipRects.reversed() {
			guard entry.rect.contains(point) else { continue }
			let clip = clips[entry.index]
			let showControls =
				entry.rect.height >= minHeightForControls
				&& entry.rect.width > playBtnSize + 8
				&& clip.url != nil

			if showControls {
				let titleStripH: CGFloat = playBtnSize + 8
				let playBtnRect = CGRect(
					x: entry.rect.minX, y: entry.rect.minY,
					width: titleStripH, height: titleStripH)
				if playBtnRect.contains(point) {
					audioPlayer?.toggle(clip: clip, index: entry.index)
					return
				}
				let scrubStripRect = CGRect(
					x: entry.rect.minX, y: entry.rect.maxY - scrubStripHeight,
					width: entry.rect.width, height: scrubStripHeight)
				if scrubStripRect.contains(point) {
					scrubbingClipIndex = entry.index
					let progress = Double((point.x - entry.rect.minX) / entry.rect.width)
					audioPlayer?.scrub(
						clip: clip, index: entry.index, progress: max(0, min(1, progress)))
					return
				}
			}

			isDraggingSelection = true
			dragHoveredIndex = entry.index
			onToggleClip?(entry.index)
			return
		}
		isDraggingSelection = true
	}

	override func mouseDragged(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		if let idx = scrubbingClipIndex, idx < clips.count,
			let clipRect = cachedClipRects.first(where: { $0.index == idx })?.rect
		{
			let progress = Double((point.x - clipRect.minX) / clipRect.width)
			audioPlayer?.scrub(clip: clips[idx], index: idx, progress: max(0, min(1, progress)))
			return
		}
		guard isDraggingSelection else { return }
		let hoveredIndex = cachedClipRects.reversed().first { $0.rect.contains(point) }?.index
		if hoveredIndex != dragHoveredIndex {
			dragHoveredIndex = hoveredIndex
			if let index = hoveredIndex {
				onToggleClip?(index)
			}
		}
	}

	override func mouseUp(with event: NSEvent) {
		scrubbingClipIndex = nil
		isDraggingSelection = false
		dragHoveredIndex = nil
	}

	override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext, duration > 0 else { return }

		let pps = bounds.width / CGFloat(max(1, duration))
		let interval = tickInterval(pixelsPerSecond: pps)

		let emptyX = CGFloat(duration) * pps
		ctx.setFillColor(NSColor.black.withAlphaComponent(0.15).cgColor)
		let emptyFillTop: CGFloat = 5 + 12 + 6  // baseline + tickHeight + gap
		let emptyFillBottom: CGFloat = bounds.height - 4
		ctx.fill(
			CGRect(
				x: emptyX, y: emptyFillTop, width: bounds.width - emptyX,
				height: emptyFillBottom - emptyFillTop))
		let baseline: CGFloat = 5

		let strokeWidth: CGFloat = 1.0
		ctx.setLineWidth(strokeWidth)

		let tickHeight: CGFloat = 12
		let attrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.boldSystemFont(ofSize: 10),
			.foregroundColor: NSColor.timelineLabel()!,
		]

		ctx.setStrokeColor(NSColor.timelineTick().cgColor)
		ctx.beginPath()

		var t = 0.0
		while t <= duration + 0.001 {  // only tick up to real duration
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

		guard !clips.isEmpty else { return }

		let laneGap: CGFloat = 4
		let clipAreaTop: CGFloat = baseline + tickHeight + 6
		let clipAreaHeight = bounds.height - clipAreaTop - 4
		let assignments = laneAssignments(for: clips)
		let numLanes = CGFloat((assignments.max() ?? 0) + 1)
		let laneHeight = max(4, (clipAreaHeight - laneGap * (numLanes - 1)) / numLanes)
		let cornerRadius: CGFloat = 6

		cachedClipRects = []
		for (i, clip) in clips.enumerated() {
			let lane = CGFloat(assignments[i])
			let x = CGFloat(clip.start) * pps
			let w = min(max(cornerRadius * 2, CGFloat(clip.end - clip.start) * pps), emptyX - x)
			let y = clipAreaTop + lane * (laneHeight + laneGap)
			let rect = CGRect(x: x, y: y, width: w, height: laneHeight)
			cachedClipRects.append((rect: rect, index: i))

			let alpha: CGFloat = selectedClips.contains(i) ? 0.85 : 0.25
			let clipColor =
				clip.isCompound
				? NSColor.warning() ?? NSColor.yellow : NSColor.accent() ?? NSColor.blue
			ctx.setFillColor(clipColor.withAlphaComponent(alpha).cgColor)
			let path = CGPath(
				roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
				transform: nil)
			ctx.addPath(path)
			ctx.fillPath()

			let showControls =
				laneHeight >= minHeightForControls && w > playBtnSize + 8 && clip.url != nil
			if let samples = waveforms[i], !samples.isEmpty {
				if showControls {
					let titleStripH: CGFloat = playBtnSize + 8
					let waveformY = rect.minY + titleStripH
					let waveformH = rect.height - titleStripH - scrubStripHeight
					if waveformH > 4 {
						drawWaveform(
							samples,
							in: CGRect(
								x: rect.minX, y: waveformY, width: rect.width, height: waveformH),
							context: ctx, selected: selectedClips.contains(i))
					}
				} else {
					drawWaveform(
						samples, in: rect, context: ctx, selected: selectedClips.contains(i))
				}
			}

			if showControls {
				let isPlaying = audioPlayer?.isPlaying(index: i) == true
				let playBtnRect = CGRect(
					x: rect.minX + 4, y: rect.minY + 4,
					width: playBtnSize, height: playBtnSize)
				drawPlayButton(in: playBtnRect, context: ctx, isPlaying: isPlaying)

				let titleX = rect.minX + 4 + playBtnSize + 10
				let titleW = rect.maxX - titleX - 6
				if titleW > 10 {
					let para = NSMutableParagraphStyle()
					para.lineBreakMode = .byTruncatingTail
					let titleAttrs: [NSAttributedString.Key: Any] = [
						.font: NSFont.systemFont(ofSize: 10, weight: .medium),
						.foregroundColor: NSColor.white.withAlphaComponent(0.85),
						.paragraphStyle: para,
					]
					let titleStr = clip.name as NSString
					let titleH = titleStr.size(withAttributes: titleAttrs).height
					let btnCenterY = rect.minY + 4 + playBtnSize / 2 + 2
					let titleY = btnCenterY - titleH / 2
					let titleRect = CGRect(x: titleX, y: titleY, width: titleW, height: titleH)
					titleStr.draw(
						with: titleRect, options: .usesLineFragmentOrigin, attributes: titleAttrs,
						context: nil)
				}

				var progress: Double?
				if isPlaying, let ct = audioPlayer?.currentTime {
					let offset = ct - clip.sourceStart
					progress = max(0, min(1, offset / clip.sourceDuration))
				}
				drawScrubBar(in: rect, context: ctx, progress: progress)
			}
		}
	}

	private func drawPlayButton(in rect: CGRect, context ctx: CGContext, isPlaying: Bool) {
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

	private func drawScrubBar(in rect: CGRect, context ctx: CGContext, progress: Double?) {
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

	private func drawWaveform(
		_ samples: [Float], in rect: CGRect, context ctx: CGContext, selected: Bool
	) {
		let alpha: CGFloat = selected ? 0.7 : 0.35
		ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)

		let barCount = max(1, Int(rect.width / 2))
		let barWidth = rect.width / CGFloat(barCount)
		let midY = rect.midY
		let halfH = rect.height * 0.35  // 70% total height, split symmetrically

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
