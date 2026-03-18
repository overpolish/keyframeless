/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import SwiftUI

struct TimelineAxisView: View {
	let duration: Double
	let format: FCPXMLParser.ProjectFormat?
	let useTimecode: Bool

	@State private var zoom: CGFloat = 1.0

	var body: some View {
		GeometryReader { geo in
			TimelineAxisScrollView(
				duration: duration,
				zoom: $zoom,
				availableWidth: geo.size.width,
				labelForTime: labelForTime
			)
		}
		.frame(height: 36)
	}

	private func labelForTime(_ seconds: Double) -> String {
		if useTimecode, let fmt = format {
			return fmt.timecode(for: seconds)
		}
		if seconds < 60 { return String(format: "%.0fs", seconds) }
		let m = Int(seconds) / 60
		let s = Int(seconds) % 60
		return s == 0 ? "\(m)m" : "\(m)m\(s)s"
	}
}

private struct TimelineAxisScrollView: NSViewRepresentable {
	let duration: Double
	@Binding var zoom: CGFloat
	let availableWidth: CGFloat
	let labelForTime: (Double) -> String

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
		docView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 36)
		docView.duration = duration
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
	var labelForTime: ((Double) -> String)?
	var onMagnify: ((CGFloat, CGFloat) -> Void)?

	override var isFlipped: Bool { true }

	override func magnify(with event: NSEvent) {
		let mouseX = convert(event.locationInWindow, from: nil).x
		onMagnify?(1 + event.magnification, mouseX)
	}

	override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext, duration > 0 else { return }

		let pps = bounds.width / CGFloat(duration)
		let interval = tickInterval(pixelsPerSecond: pps)
		let baseline = bounds.height - 1

		ctx.setLineWidth(0.5)

		ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.3).cgColor)
		ctx.move(to: CGPoint(x: 0, y: baseline))
		ctx.addLine(to: CGPoint(x: bounds.width, y: baseline))
		ctx.strokePath()

		let attrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 9),
			.foregroundColor: NSColor.secondaryLabelColor,
		]

		var t = 0.0
		while t <= duration + 0.001 {
			let x = CGFloat(t) * pps

			ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor)
			ctx.move(to: CGPoint(x: x, y: baseline - 10))
			ctx.addLine(to: CGPoint(x: x, y: baseline))
			ctx.strokePath()

			let label = labelForTime?(t) ?? String(format: "%.0fs", t)
			(label as NSString).draw(at: CGPoint(x: x + 3, y: baseline - 20), withAttributes: attrs)

			t += interval
		}
	}

	private func tickInterval(pixelsPerSecond: CGFloat) -> Double {
		let minSpacing: CGFloat = 70
		let candidates = [0.5, 1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600]
		return candidates.first { CGFloat($0) * pixelsPerSecond >= minSpacing } ?? 600
	}
}
