/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
// the routing - only a real mouseDown on an NSView that accepts first responder
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
	var showRoleLabels: Bool = false
	/// Sonar: reserve the spectrogram lane, so it holds its space even with
	/// nothing selected. Off in Steno.
	var showSpectrogramLane: Bool = false
	/// Sonar: drawn as a lane under the clips, sharing this timeline's zoom and
	/// scroll. nil in Steno, or when nothing is selected.
	var spectrogram: Spectrogram? = nil
	/// Sonar: an analysis is running, so the band shows a stale picture.
	var spectrogramLoading: Bool = false
	var hoveredClipIndex: Binding<Int?> = .constant(nil)
	var onClickDimmed: ((Int) -> Void)? = nil
	var onLoadingChanged: ((Set<Int>) -> Void)? = nil

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
				showRoleLabels: showRoleLabels,
				showSpectrogramLane: showSpectrogramLane,
				spectrogram: spectrogram,
				spectrogramLoading: spectrogramLoading,
				hoveredClipIndex: hoveredClipIndex,
				onClickDimmed: onClickDimmed,
				onLoadingChanged: onLoadingChanged
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
	var showRoleLabels: Bool = false
	var showSpectrogramLane: Bool = false
	var spectrogram: Spectrogram?
	var spectrogramLoading: Bool = false
	var hoveredClipIndex: Binding<Int?>
	var onClickDimmed: ((Int) -> Void)?
	var onLoadingChanged: ((Set<Int>) -> Void)?

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

		// onLoadingChanged must be wired BEFORE clips, since clips' didSet kicks off
		// waveform tasks and reports the initial loading state synchronously.
		docView.onLoadingChanged = onLoadingChanged

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

		if docView.showSpectrogramLane != showSpectrogramLane {
			docView.showSpectrogramLane = showSpectrogramLane
			docView.needsDisplay = true
		}
		if docView.spectrogramID != spectrogram?.id {
			docView.setSpectrogram(spectrogram)
			docView.needsDisplay = true
		}
		if docView.spectrogramLoading != spectrogramLoading {
			docView.spectrogramLoading = spectrogramLoading
			docView.needsDisplay = true
		}
		if docView.showRoleLabels != showRoleLabels {
			docView.showRoleLabels = showRoleLabels
			docView.needsDisplay = true
		}
		let oldHovered = docView.hoveredClipIndex
		docView.hoveredClipIndex = hoveredClipIndex.wrappedValue
		if hoveredClipIndex.wrappedValue != oldHovered {
			stateChanged = true
			if hoveredClipIndex.wrappedValue != nil {
				docView.startPulse()
			} else {
				docView.stopPulseIfIdle()
			}
		}
		docView.onToggleClip = { index in
			if selectedClips.contains(index) {
				selectedClips.remove(index)
			} else {
				selectedClips.insert(index)
			}
		}
		docView.onSetClipSelected = { index, shouldSelect in
			if shouldSelect {
				selectedClips.insert(index)
			} else {
				selectedClips.remove(index)
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
	var showRoleLabels = false
	var showSpectrogramLane = false
	var onHoverClip: ((Int?) -> Void)?

	/// Rasterising the spectrogram is expensive, so keep the bitmap and rebuild
	/// only when a new analysis arrives (tracked by id) or the zoom changes
	/// enough that the current bitmap would be visibly upscaled.
	private(set) var spectrogramID: UUID?
	fileprivate var spectrogram: Spectrogram?
	fileprivate var spectrogramCG: CGImage?
	fileprivate var spectrogramLoading = false
	/// One column per STFT frame up to here; past it the overview buckets frames
	/// together and `detailCG` takes over for the visible slice.
	fileprivate static let overviewMaxColumns = 16384
	fileprivate var detailCG: CGImage?
	fileprivate var detailStart: Double = 0
	fileprivate var detailDuration: Double = 0
	private var detailRange: Range<Int>?
	private var detailRequestedRange: Range<Int>?
	private var detailTask: Task<Void, Never>?
	fileprivate var spectrogramStart: Double = 0
	fileprivate var spectrogramDuration: Double = 0
	private var rasterTask: Task<Void, Never>?

	/// `spectrogramStart`/`spectrogramDuration` describe the image currently on
	/// screen, NOT the data - they're updated only when a raster lands. Holding
	/// the last good picture until its replacement is ready is what stops the
	/// band flashing empty on every re-render, and keeping the range with the
	/// pixels is what stops the old image being stretched across the new one's
	/// time span while we wait.
	func setSpectrogram(_ spectrogram: Spectrogram?) {
		self.spectrogram = spectrogram
		spectrogramID = spectrogram?.id
		detailRange = nil
		detailRequestedRange = nil
		detailCG = nil
		guard spectrogram != nil else {
			rasterTask?.cancel()
			detailTask?.cancel()
			spectrogramCG = nil
			spectrogramStart = 0
			spectrogramDuration = 0
			setNeedsDisplay(bounds)
			return
		}
		rebuildSpectrogram()
	}

	/// Rasterise ONCE per spectrogram, at the data's own resolution (one column
	/// per STFT frame, capped at a sane texture size).
	///
	/// Deliberately independent of zoom. Sizing the bitmap to the zoomed canvas
	/// meant every zoom step rebuilt the whole timeline - cost scaling with
	/// project length x zoom, to show a screenful. At data resolution there's no
	/// more detail to be had, so zooming is just Core Graphics drawing the image,
	/// clipped to the dirty rect: bounded by screen pixels, like the waveform.
	fileprivate func rebuildSpectrogram() {
		guard let spectrogram else { return }
		let target = max(1, min(spectrogram.numFrames, Self.overviewMaxColumns))
		rasterTask?.cancel()
		let spec = spectrogram
		let renderedID = spec.id
		rasterTask = Task { [weak self] in
			guard let buffer = await spec.rgbPixels(maxWidth: target), !Task.isCancelled,
				let self, self.spectrogramID == renderedID, let image = buffer.cgImage()
			else { return }
			// Pixels and their time range land together, so the band never draws one
			// spectrogram's image against another's span.
			self.spectrogramCG = image
			self.spectrogramStart = spec.timelineStart
			self.spectrogramDuration = spec.duration
			self.setNeedsDisplay(self.bounds)
			self.rebuildSpectrogramDetailIfNeeded()
		}
	}

	/// Rasters the visible slice at screen resolution, drawn over the overview.
	///
	/// The overview caps at `overviewMaxColumns`, so detail stops improving at
	/// roughly 8x zoom no matter how long the project is - fine for a 4-minute
	/// timeline (whose every frame fits under the cap), useless for an hour-long
	/// one where you can never look closer than ~7 minutes of timeline. This
	/// covers only what's on screen, so its cost is screen-sized and constant
	/// rather than growing with the project.
	///
	/// Skipped entirely when the overview already has a column per frame on
	/// screen - there's no more detail in the data to fetch.
	fileprivate func rebuildSpectrogramDetailIfNeeded() {
		guard let spectrogram, duration > 0, bounds.width > 0, spectrogram.numFrames > 0,
			let clipView = superview as? NSClipView
		else { return }
		let visible = clipView.documentVisibleRect
		guard visible.width > 1 else { return }

		let pps = bounds.width / CGFloat(duration)
		let startTime = max(Double(visible.minX / pps), spectrogram.timelineStart)
		let endTime = min(
			Double(visible.maxX / pps), spectrogram.timelineStart + spectrogram.duration)
		guard endTime > startTime else { return }

		let hop = spectrogram.hopSeconds
		let loFrame = max(0, Int((startTime - spectrogram.timelineStart) / hop))
		let hiFrame = min(
			spectrogram.numFrames, Int(((endTime - spectrogram.timelineStart) / hop).rounded(.up)))
		guard hiFrame > loFrame else { return }

		// Screen columns available for those frames. If the overview already
		// resolves them one-to-one, the detail pass would be identical work for an
		// identical picture.
		let screenColumns = Int((CGFloat(endTime - startTime) * pps).rounded())
		let overviewColumnsHere =
			Int(
				(CGFloat(endTime - startTime) / CGFloat(spectrogram.duration))
					* CGFloat(min(spectrogram.numFrames, Self.overviewMaxColumns)))
		guard screenColumns > overviewColumnsHere, hiFrame - loFrame > overviewColumnsHere else {
			// The overview already resolves every frame on screen; a detail pass
			// would be the same work for the same picture.
			detailRequestedRange = nil
			if detailCG != nil {
				detailCG = nil
				setNeedsDisplay(bounds)
			}
			return
		}

		// Pad beyond the visible slice and snap to a coarse grid, so nudging the
		// scroll reuses the same raster instead of starting a new one every pixel.
		let pad = (hiFrame - loFrame) / 2
		let grid = 256
		let lo = max(0, ((loFrame - pad) / grid) * grid)
		let hi = min(spectrogram.numFrames, (((hiFrame + pad) / grid) + 1) * grid)
		guard hi > lo else { return }
		let range = lo..<hi

		// Guard on the REQUESTED range, not the rendered one: a zoom gesture
		// redraws constantly, and comparing against the rendered range would cancel
		// and restart the in-flight raster on every frame so it never finished.
		guard range != detailRequestedRange else { return }
		detailRequestedRange = range

		let target = max(1, min(screenColumns * 2, range.count, Self.overviewMaxColumns))
		detailTask?.cancel()
		let spec = spectrogram
		let renderedID = spec.id
		detailTask = Task { [weak self] in
			// Let a gesture settle before spending anything.
			try? await Task.sleep(for: .milliseconds(120))
			guard !Task.isCancelled,
				let buffer = await spec.rgbPixels(maxWidth: target, frameRange: range),
				!Task.isCancelled, let self, self.spectrogramID == renderedID,
				let image = buffer.cgImage()
			else { return }
			self.detailCG = image
			self.detailRange = range
			self.detailStart = spec.timelineStart + Double(range.lowerBound) * spec.hopSeconds
			self.detailDuration = Double(range.count) * spec.hopSeconds
			self.setNeedsDisplay(self.bounds)
		}
	}
	var onToggleClip: ((Int) -> Void)?
	var onSetClipSelected: ((Int, Bool) -> Void)?
	fileprivate var dragTargetSelected: Bool?
	fileprivate var dragVisitedIndices: Set<Int> = []
	var onClickDimmed: ((Int) -> Void)?
	var onLoadingChanged: ((Set<Int>) -> Void)?
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
			if index != nil { startPulse() } else { stopPulseIfIdle() }
			needsDisplay = true
		}
	}

	override func mouseExited(with event: NSEvent) {
		if localHoveredIndex != nil {
			localHoveredIndex = nil
		}
		stopPulseIfIdle()
		needsDisplay = true
	}

	fileprivate func stopPulseIfIdle() {
		if hoveredClipIndex == nil && localHoveredIndex == nil && waveformTasks.isEmpty {
			stopPulse()
		}
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
		// to the extension - see TimelineFirstResponder comment.
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
			let target = !selectedClips.contains(entry.index)
			dragTargetSelected = target
			dragVisitedIndices = [entry.index]
			onSetClipSelected?(entry.index, target)
			return
		}
		isDraggingSelection = true
		dragTargetSelected = nil
		dragVisitedIndices = []
		dragHoveredIndex = nil
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
			if let index = hoveredIndex, !dragVisitedIndices.contains(index) {
				let target = dragTargetSelected ?? !selectedClips.contains(index)
				dragTargetSelected = target
				dragVisitedIndices.insert(index)
				onSetClipSelected?(index, target)
			}
		}
		if hoveredIndex != localHoveredIndex {
			localHoveredIndex = hoveredIndex
			needsDisplay = true
		}
	}

	override func mouseUp(with event: NSEvent) {
		scrubbingClipIndex = nil
		isDraggingSelection = false
		dragHoveredIndex = nil
		dragVisitedIndices = []
		dragTargetSelected = nil
	}

	override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext else { return }

		// Cheap: returns immediately unless the visible frame range actually
		// changed. Unlike the old per-draw rebuild, it can't kick off a raster of
		// the whole timeline - only of what's on screen.
		rebuildSpectrogramDetailIfNeeded()
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
			loadingIndices: Set(waveformTasks.keys),
			hasAudioPlayer: audioPlayer != nil,
			playingIndex: audioPlayer?.playingIndex,
			labelForTime: labelForTime,
			skipWaveforms: inLiveResize,
			showSpectrogramLane: showSpectrogramLane,
			spectrogramImage: spectrogramCG,
			spectrogramDetailImage: detailCG,
			spectrogramDetailStart: detailStart,
			spectrogramDetailDuration: detailDuration,
			spectrogramLoading: spectrogramLoading,
			spectrogramStart: spectrogramStart,
			spectrogramDuration: spectrogramDuration,
			showRoleLabels: showRoleLabels,
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
		let changed = clips.map(AudioClipFingerprint.of) != oldClips.map(AudioClipFingerprint.of)
		if changed {
			waveformTasks.values.forEach { $0.cancel() }
			waveformTasks = [:]
			waveforms = [:]
		}
		for (i, clip) in clips.enumerated() {
			guard waveforms[i] == nil, waveformTasks[i] == nil else { continue }
			waveformTasks[i] = Task { [weak self] in
				let onProgress: @Sendable ([Float]) -> Void = { [weak self] partial in
					Task { @MainActor [weak self] in
						guard let self else { return }
						self.waveforms[i] = partial
						self.needsDisplay = true
					}
				}
				guard
					let samples = try? await WaveformLoader.shared.waveform(
						for: clip, onProgress: onProgress)
				else {
					await MainActor.run { [weak self] in
						self?.waveformTasks[i] = nil
						self?.reportLoadingState()
					}
					return
				}
				await MainActor.run { [weak self] in
					self?.waveforms[i] = samples
					self?.waveformTasks[i] = nil
					self?.needsDisplay = true
					self?.reportLoadingState()
				}
			}
		}
		reportLoadingState()
	}

	private func reportLoadingState() {
		let loadingSet = Set(waveformTasks.keys)
		if !loadingSet.isEmpty {
			startPulse()
		} else if hoveredClipIndex == nil && localHoveredIndex == nil {
			stopPulse()
		}
		needsDisplay = true
		if let onLoadingChanged {
			DispatchQueue.main.async { onLoadingChanged(loadingSet) }
		}
	}
}
