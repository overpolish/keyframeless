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
	var audioPlayer: AudioPlayer? = nil
	var visibleIndices: Set<Int>? = nil
	var dimmedIndices: Set<Int> = []
	var showWaveforms: Bool = true
	var hoveredClipIndex: Binding<Int?> = .constant(nil)
	var onClickDimmed: ((Int) -> Void)? = nil

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
				audioPlayer: audioPlayer,
				visibleIndices: visibleIndices,
				dimmedIndices: dimmedIndices,
				showWaveforms: showWaveforms,
				hoveredClipIndex: hoveredClipIndex,
				onClickDimmed: onClickDimmed
			)
		}
		.padding(.horizontal, KKPaddingMD)
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
	var audioPlayer: AudioPlayer?
	var visibleIndices: Set<Int>?
	var dimmedIndices: Set<Int> = []
	var showWaveforms: Bool
	var hoveredClipIndex: Binding<Int?>
	var onClickDimmed: ((Int) -> Void)?

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
		docView.visibleIndices = visibleIndices
		docView.dimmedIndices = dimmedIndices
		docView.showWaveforms = showWaveforms
		docView.hoveredClipIndex = hoveredClipIndex.wrappedValue
		docView.onHoverClip = { index in
			hoveredClipIndex.wrappedValue = index
		}
		docView.onToggleClip = { index in
			if selectedClips.contains(index) {
				selectedClips.remove(index)
			} else {
				selectedClips.insert(index)
			}
		}
		docView.onClickDimmed = onClickDimmed
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
		didSet { if showWaveforms { loadWaveformsIfNeeded(from: oldValue) } }
	}
	var selectedClips: Set<Int> = []
	var visibleIndices: Set<Int>?
	var dimmedIndices: Set<Int> = []
	var showWaveforms: Bool = true
	var hoveredClipIndex: Int?
	var onHoverClip: ((Int?) -> Void)?
	var onToggleClip: ((Int) -> Void)?
	var onClickDimmed: ((Int) -> Void)?
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
	private var pulseTimer: Timer?
	private var pulsePhase: CGFloat = 0

	private let playBtnSize: CGFloat = 12
	private let minHeightForControls: CGFloat = 16
	private let scrubStripHeight: CGFloat = 14

	private var trackingArea: NSTrackingArea?

	override var isFlipped: Bool { true }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let existing = trackingArea { removeTrackingArea(existing) }
		trackingArea = NSTrackingArea(
			rect: bounds,
			options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(trackingArea!)
	}

	override func mouseMoved(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let index = cachedClipRects.reversed().first { $0.rect.contains(point) }?.index
		if index != hoveredClipIndex {
			onHoverClip?(index)
			if index != nil { startPulse() } else { stopPulse() }
		}
	}

	override func mouseExited(with event: NSEvent) {
		if hoveredClipIndex != nil {
			onHoverClip?(nil)
		}
		stopPulse()
	}

	override func magnify(with event: NSEvent) {
		let mouseX = convert(event.locationInWindow, from: nil).x
		onMagnify?(1 + event.magnification, mouseX)
	}

	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		for entry in cachedClipRects.reversed() {
			guard entry.rect.contains(point) else { continue }
			if dimmedIndices.contains(entry.index) {
				onClickDimmed?(entry.index)
				return
			}
			if handleAudioControlClick(point: point, entry: entry) { return }

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
		let hoveredIndex = cachedClipRects.reversed().first {
			$0.rect.contains(point) && !dimmedIndices.contains($0.index)
		}?.index
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
		guard let ctx = NSGraphicsContext.current?.cgContext else { return }

		let renderer = TimelineAxisRenderer(
			bounds: bounds,
			duration: duration,
			clips: clips,
			selectedClips: selectedClips,
			visibleIndices: visibleIndices,
			dimmedIndices: dimmedIndices,
			showWaveforms: showWaveforms,
			hoveredClipIndex: hoveredClipIndex,
			pulsePhase: pulsePhase,
			waveforms: waveforms,
			hasAudioPlayer: audioPlayer != nil,
			playingIndex: audioPlayer?.playingIndex,
			currentTime: audioPlayer?.currentTime,
			labelForTime: labelForTime
		)
		renderer.draw(in: ctx, cachedClipRects: &cachedClipRects)
	}

	private func handleAudioControlClick(
		point: CGPoint, entry: (rect: CGRect, index: Int)
	) -> Bool {
		let clip = clips[entry.index]
		let hasAudioControls =
			audioPlayer != nil
			&& entry.rect.height >= minHeightForControls
			&& entry.rect.width > playBtnSize + 8
			&& clip.url != nil

		guard hasAudioControls else { return false }

		let titleStripH: CGFloat = playBtnSize + 8
		let playBtnRect = CGRect(
			x: entry.rect.minX, y: entry.rect.minY,
			width: titleStripH, height: titleStripH)
		if playBtnRect.contains(point) {
			audioPlayer?.toggle(clip: clip, index: entry.index)
			return true
		}
		let scrubStripRect = CGRect(
			x: entry.rect.minX, y: entry.rect.maxY - scrubStripHeight,
			width: entry.rect.width, height: scrubStripHeight)
		if scrubStripRect.contains(point) {
			scrubbingClipIndex = entry.index
			let progress = Double((point.x - entry.rect.minX) / entry.rect.width)
			audioPlayer?.scrub(
				clip: clip, index: entry.index, progress: max(0, min(1, progress)))
			return true
		}
		return false
	}

	private func startPulse() {
		guard pulseTimer == nil else { return }
		pulsePhase = 0
		pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
			[weak self] _ in
			guard let self else { return }
			self.pulsePhase += CGFloat(1.0 / 30)
			self.needsDisplay = true
		}
	}

	private func stopPulse() {
		pulseTimer?.invalidate()
		pulseTimer = nil
		pulsePhase = 0
	}

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
}
