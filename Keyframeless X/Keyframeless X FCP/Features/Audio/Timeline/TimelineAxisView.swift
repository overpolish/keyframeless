/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import KeyframelessKit
import SwiftUI

// Spacebar-to-stop in FCP workflow extensions:
//
// FCP intercepts key events at the host level. The extension's local event
// monitors (NSEvent.addLocalMonitorForEvents) never receive keyDown unless a
// native NSView has been made first responder through an actual user click.
// Programmatic makeFirstResponder calls (e.g. in viewDidAppear) do NOT prime
// the routing — only a real mouseDown on an NSView that accepts first responder
// causes the system to start forwarding key events to the extension process.
//
// Solution: AxisDocumentView accepts first responder and overrides keyDown to
// catch spacebar. On the setup page the user clicks the timeline directly, so
// mouseDown makes it first responder naturally. On the edit page the user
// clicks SwiftUI play buttons instead, so AudioEditView's click monitor calls
// TimelineFirstResponder.claim() during the real mouseDown event to redirect
// first responder to the timeline's AxisDocumentView.
enum TimelineFirstResponder {
	fileprivate static weak var view: NSView?

	static func claim(in window: NSWindow?) {
		guard let view, let window, view.window == window else { return }
		window.makeFirstResponder(view)
	}
}

struct TimelineAxisView: View {
	let duration: Double
	let format: FCPXMLParser.ProjectFormat?
	let useTimecode: Bool
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>
	var audioPlayer: AudioPlayer? = nil
	var visibleIndices: Set<Int>? = nil
	var dimmedIndices: Set<Int> = []
	var overlapRegions: [CaptionBuilder.OverlapRegion] = []
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
				overlapRegions: overlapRegions,
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
	var overlapRegions: [CaptionBuilder.OverlapRegion] = []
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
		TimelineFirstResponder.view = docView
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
		let newFrame = NSRect(x: 0, y: 0, width: contentWidth, height: docHeight)
		let frameChanged = docView.frame != newFrame
		docView.frame = newFrame

		var stateChanged = frameChanged
		if docView.duration != duration {
			docView.duration = duration
			stateChanged = true
		}
		if docView.selectedClips != selectedClips {
			docView.selectedClips = selectedClips
			stateChanged = true
		}
		if docView.visibleIndices != visibleIndices {
			docView.visibleIndices = visibleIndices
			stateChanged = true
		}
		if docView.dimmedIndices != dimmedIndices {
			docView.dimmedIndices = dimmedIndices
			stateChanged = true
		}
		if docView.showWaveforms != showWaveforms {
			docView.showWaveforms = showWaveforms
			stateChanged = true
		}

		// clips triggers waveform loading via didSet, so always assign through the setter
		let clipsChanged =
			clips.map(\.url) != docView.clips.map(\.url)
			|| clips.count != docView.clips.count
		if clipsChanged {
			docView.clips = clips
			stateChanged = true
		}

		docView.audioPlayer = audioPlayer
		docView.overlapRegions = overlapRegions

		let oldHovered = docView.hoveredClipIndex
		docView.hoveredClipIndex = hoveredClipIndex.wrappedValue
		if hoveredClipIndex.wrappedValue != oldHovered {
			stateChanged = true
			if hoveredClipIndex.wrappedValue != nil {
				docView.startPulse()
			} else if docView.localHoveredIndex == nil {
				docView.stopPulse()
			}
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

		if stateChanged {
			docView.needsDisplay = true
		}
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
	var overlapRegions: [CaptionBuilder.OverlapRegion] = []
	var showWaveforms: Bool = true
	var hoveredClipIndex: Int?
	var onHoverClip: ((Int?) -> Void)?
	var onToggleClip: ((Int) -> Void)?
	var onClickDimmed: ((Int) -> Void)?
	var labelForTime: ((Double) -> String)?
	var onMagnify: ((CGFloat, CGFloat) -> Void)?
	var audioPlayer: AudioPlayer? {
		didSet {
			guard audioPlayer !== oldValue else { return }
			cancellables = []
			guard let audioPlayer else {
				hidePlaybackOverlay()
				return
			}
			audioPlayer.$playingIndex
				.receive(on: RunLoop.main)
				.sink { [weak self] _ in self?.needsDisplay = true }
				.store(in: &cancellables)
			audioPlayer.currentTimeSubject
				.receive(on: RunLoop.main)
				.sink { [weak self] _ in self?.updatePlaybackOverlay() }
				.store(in: &cancellables)
		}
	}

	fileprivate var localHoveredIndex: Int?
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
	private var progressFillLayer: CALayer?
	private var knobOverlayLayer: CALayer?

	private var trackingArea: NSTrackingArea?

	// See TimelineFirstResponder comment for why this view handles keyboard events.
	override var acceptsFirstResponder: Bool { true }
	override var isFlipped: Bool { true }
	override var wantsLayer: Bool {
		get { true }
		set {}
	}

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
		if index != localHoveredIndex {
			localHoveredIndex = index
			if index != nil { startPulse() } else { stopPulse() }
			needsDisplay = true
		}
	}

	override func mouseExited(with event: NSEvent) {
		if localHoveredIndex != nil {
			localHoveredIndex = nil
		}
		stopPulse()
		needsDisplay = true
	}

	override func magnify(with event: NSEvent) {
		let mouseX = convert(event.locationInWindow, from: nil).x
		onMagnify?(1 + event.magnification, mouseX)
	}

	override func keyDown(with event: NSEvent) {
		if event.keyCode == 49, AudioPlayer.isAnyPlaying {
			AudioPlayer.stopAll()
		} else {
			super.keyDown(with: event)
		}
	}

	override func mouseDown(with event: NSEvent) {
		// Claiming first responder on click primes FCP's key event routing
		// to the extension — see TimelineFirstResponder comment.
		window?.makeFirstResponder(self)
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
			overlapRegions: overlapRegions,
			showWaveforms: showWaveforms,
			hoveredClipIndex: hoveredClipIndex,
			glowClipIndex: hoveredClipIndex ?? localHoveredIndex,
			pulsePhase: pulsePhase,
			waveforms: waveforms,
			hasAudioPlayer: audioPlayer != nil,
			playingIndex: audioPlayer?.playingIndex,
			labelForTime: labelForTime,
			skipWaveforms: inLiveResize,
			dirtyRect: dirtyRect
		)
		renderer.draw(in: ctx, cachedClipRects: &cachedClipRects)
		updatePlaybackOverlay()
	}

	override func viewDidEndLiveResize() {
		super.viewDidEndLiveResize()
		needsDisplay = true
	}

	private func ensureOverlayLayers() {
		guard let viewLayer = layer else { return }
		if progressFillLayer == nil {
			let fill = CALayer()
			fill.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
			fill.cornerRadius = 1.5
			fill.isHidden = true
			viewLayer.addSublayer(fill)
			progressFillLayer = fill
		}
		if knobOverlayLayer == nil {
			let knob = CALayer()
			knob.backgroundColor = NSColor.white.cgColor
			knob.cornerRadius = 4.5
			knob.isHidden = true
			viewLayer.addSublayer(knob)
			knobOverlayLayer = knob
		}
	}

	private func updatePlaybackOverlay() {
		ensureOverlayLayers()
		guard let audioPlayer,
			let playIdx = audioPlayer.playingIndex,
			let time = audioPlayer.currentTime,
			playIdx < clips.count,
			let entry = cachedClipRects.first(where: { $0.index == playIdx })
		else {
			hidePlaybackOverlay()
			return
		}
		let clip = clips[playIdx]
		let offset = time - clip.sourceStart
		let progress = CGFloat(max(0, min(1, offset / clip.sourceDuration)))
		let trackH: CGFloat = 3
		let trackX = entry.rect.minX
		let trackW = entry.rect.width
		let trackY = entry.rect.maxY - trackH - 5
		let fillW = trackW * progress
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		progressFillLayer?.frame = CGRect(
			x: trackX, y: trackY, width: max(0, fillW), height: trackH)
		progressFillLayer?.isHidden = false
		let knobR: CGFloat = 4.5
		knobOverlayLayer?.frame = CGRect(
			x: trackX + fillW - knobR, y: trackY + trackH / 2 - knobR,
			width: knobR * 2, height: knobR * 2)
		knobOverlayLayer?.isHidden = false
		CATransaction.commit()
	}

	private func hidePlaybackOverlay() {
		progressFillLayer?.isHidden = true
		knobOverlayLayer?.isHidden = true
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

	fileprivate func startPulse() {
		guard pulseTimer == nil else { return }
		pulsePhase = 0
		pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
			[weak self] _ in
			guard let self else { return }
			self.pulsePhase += CGFloat(1.0 / 30)
			self.needsDisplay = true
		}
	}

	fileprivate func stopPulse() {
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
