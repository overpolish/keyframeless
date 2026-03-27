/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct FCPDragZoneView: NSViewRepresentable {
	let xmlProvider: () -> String
	let onDragStateChanged: (Bool) -> Void
	var showWarning = false

	func makeNSView(context: Context) -> FCPDragSourceView {
		let view = FCPDragSourceView()
		view.xmlProvider = xmlProvider
		view.onDragStateChanged = onDragStateChanged
		view.showWarning = showWarning
		return view
	}

	func updateNSView(_ nsView: FCPDragSourceView, context: Context) {
		nsView.xmlProvider = xmlProvider
		nsView.onDragStateChanged = onDragStateChanged
		nsView.showWarning = showWarning
		nsView.needsDisplay = true
	}
}

private let fcpPasteboardTypes = [
	"com.apple.finalcutpro.xml.v1-10", "com.apple.finalcutpro.xml.v1-9",
	"com.apple.finalcutpro.xml",
]
.map { NSPasteboard.PasteboardType($0) }

class FCPXMLItemProvider: NSObject, NSPasteboardItemDataProvider {
	private let xml: String

	init(xml: String) {
		self.xml = xml
	}

	func pasteboard(
		_ pasteboard: NSPasteboard?,
		item: NSPasteboardItem,
		provideDataForType type: NSPasteboard.PasteboardType
	) {
		guard fcpPasteboardTypes.contains(type),
			let data = xml.data(using: .utf8)
		else { return }
		item.setData(data, forType: type)
	}
}

class FCPDragSourceView: NSView, NSDraggingSource {
	var xmlProvider: (() -> String)?
	var onDragStateChanged: ((Bool) -> Void)?
	var showWarning = false

	override func draw(_ dirtyRect: NSRect) {
		let accentColor: NSColor =
			showWarning ? .warning() ?? .controlAccentColor : .controlAccentColor

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
		guard let xmlProvider else { return }
		let xml = xmlProvider()

		let provider = FCPXMLItemProvider(xml: xml)
		let item = NSPasteboardItem()
		item.setDataProvider(provider, forTypes: fcpPasteboardTypes)

		let draggingItem = NSDraggingItem(pasteboardWriter: item)
		draggingItem.setDraggingFrame(bounds, contents: snapshot())

		onDragStateChanged?(true)
		beginDraggingSession(with: [draggingItem], event: event, source: self)
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
}
