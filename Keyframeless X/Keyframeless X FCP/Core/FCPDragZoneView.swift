/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct FCPDragZoneView: NSViewRepresentable {
	let nativeDataProvider: () -> Data?
	let onDragStateChanged: (Bool) -> Void

	func makeNSView(context: Context) -> FCPDragSourceView {
		let view = FCPDragSourceView()
		view.nativeDataProvider = nativeDataProvider
		view.onDragStateChanged = onDragStateChanged
		return view
	}

	func updateNSView(_ nsView: FCPDragSourceView, context: Context) {
		nsView.nativeDataProvider = nativeDataProvider
		nsView.onDragStateChanged = onDragStateChanged
		nsView.needsDisplay = true
	}
}

private let proFFPasteboardType = NSPasteboard.PasteboardType(
	"com.apple.flexo.proFFPasteboardUTI"
)

class FCPDragSourceView: NSView, NSDraggingSource {
	var nativeDataProvider: (() -> Data?)?
	var onDragStateChanged: ((Bool) -> Void)?

	override func draw(_ dirtyRect: NSRect) {
		let accentColor: NSColor = .controlAccentColor

		let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
		accentColor.withAlphaComponent(0.15).setFill()
		path.fill()
		accentColor.withAlphaComponent(0.6).setStroke()
		path.lineWidth = 1.5
		let dashes: [CGFloat] = [6, 4]
		path.setLineDash(dashes, count: dashes.count, phase: 0)
		path.stroke()

		let iconAttachment = NSTextAttachment()
		let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
		iconAttachment.image = NSImage(
			systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)?
			.withSymbolConfiguration(iconConfig)

		let iconString = NSAttributedString(attachment: iconAttachment)
		let labelString = NSAttributedString(
			string: " Drag to FCP",
			attributes: [
				.font: NSFont.systemFont(ofSize: 11, weight: .medium),
				.foregroundColor: accentColor,
			])

		let combined = NSMutableAttributedString()
		combined.append(iconString)
		combined.append(labelString)
		combined.addAttribute(
			.foregroundColor, value: accentColor,
			range: NSRange(location: 0, length: combined.length))

		let size = combined.size()
		let origin = CGPoint(
			x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
		combined.draw(at: origin)
	}

	override func mouseDown(with event: NSEvent) {
		guard let nativeDataProvider, let data = nativeDataProvider(),
			!data.isEmpty
		else { return }

		let pbItem = NSPasteboardItem()
		pbItem.setData(data, forType: proFFPasteboardType)

		let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
		draggingItem.setDraggingFrame(bounds, contents: snapshot())

		onDragStateChanged?(true)
		let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
		session.animatesToStartingPositionsOnCancelOrFail = true
	}

	func draggingSession(
		_ session: NSDraggingSession,
		sourceOperationMaskFor context: NSDraggingContext
	) -> NSDragOperation {
		.copy
	}

	func draggingSession(
		_ session: NSDraggingSession,
		endedAt screenPoint: NSPoint,
		operation: NSDragOperation
	) {
		onDragStateChanged?(false)
	}

	private func snapshot() -> NSImage {
		let image = NSImage(size: bounds.size)
		image.lockFocus()
		if let ctx = NSGraphicsContext.current?.cgContext {
			layer?.render(in: ctx)
		}
		image.unlockFocus()
		return image
	}

	static func pasteToTimeline(data: Data) {
		let pb = NSPasteboard.general
		pb.clearContents()
		pb.setData(data, forType: proFFPasteboardType)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			let src = CGEventSource(stateID: .hidSystemState)
			let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
			keyDown?.flags = .maskCommand
			let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
			keyUp?.flags = .maskCommand
			keyDown?.post(tap: .cghidEventTap)
			keyUp?.post(tap: .cghidEventTap)
		}
	}
}
