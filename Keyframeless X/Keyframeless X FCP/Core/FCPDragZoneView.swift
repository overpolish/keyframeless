/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import SwiftUI

struct FCPDragZoneView: NSViewRepresentable {
	func makeNSView(context: Context) -> FCPDragSourceView {
		FCPDragSourceView()
	}

	func updateNSView(_ nsView: FCPDragSourceView, context: Context) {}
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
	override func draw(_ dirtyRect: NSRect) {
		let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
		NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
		path.fill()
		NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
		path.lineWidth = 1.5
		let dashes: [CGFloat] = [6, 4]
		path.setLineDash(dashes, count: dashes.count, phase: 0)
		path.stroke()

		let label = "Drag to FCP" as NSString
		let attrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 11),
			.foregroundColor: NSColor.secondaryLabelColor,
		]
		let size = label.size(withAttributes: attrs)
		let origin = CGPoint(
			x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
		label.draw(at: origin, withAttributes: attrs)
	}

	override func mouseDown(with event: NSEvent) {
		let xml = FCPXMLBuilder.titleStorylineXML(text: "hello from keyframeless x")
		print(xml)

		let provider = FCPXMLItemProvider(xml: xml)
		let item = NSPasteboardItem()
		item.setDataProvider(provider, forTypes: fcpPasteboardTypes)

		let draggingItem = NSDraggingItem(pasteboardWriter: item)
		draggingItem.setDraggingFrame(bounds, contents: snapshot())

		beginDraggingSession(with: [draggingItem], event: event, source: self)
	}

	func draggingSession(
		_ session: NSDraggingSession,
		sourceOperationMaskFor context: NSDraggingContext
	) -> NSDragOperation {
		.copy
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
