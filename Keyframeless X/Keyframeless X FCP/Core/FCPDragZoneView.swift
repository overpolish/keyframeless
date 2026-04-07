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

		let lineWidth: CGFloat = 1.5
		let strokeInset = lineWidth / 2 + 0.5
		let strokePath = NSBezierPath(
			roundedRect: bounds.insetBy(dx: strokeInset, dy: strokeInset), xRadius: 6, yRadius: 6)
		let fillPath = NSBezierPath(
			roundedRect: bounds.insetBy(
				dx: strokeInset + lineWidth / 2, dy: strokeInset + lineWidth / 2), xRadius: 5,
			yRadius: 5)
		accentColor.withAlphaComponent(0.15).setFill()
		fillPath.fill()
		accentColor.withAlphaComponent(0.6).setStroke()
		strokePath.lineWidth = lineWidth
		let dashes: [CGFloat] = [6, 4]
		strokePath.setLineDash(dashes, count: dashes.count, phase: 0)
		strokePath.stroke()

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

		let dragEvent = event
		let dragData = data

		ensureCaptionRoleExists { [weak self] in
			guard let self else { return }
			let pbItem = NSPasteboardItem()
			pbItem.setData(dragData, forType: proFFPasteboardType)

			let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
			draggingItem.setDraggingFrame(bounds, contents: snapshot())

			onDragStateChanged?(true)
			let session = beginDraggingSession(with: [draggingItem], event: dragEvent, source: self)
			session.animatesToStartingPositionsOnCancelOrFail = true
		}
	}

	// FCP's drag handler doesn't create custom roles from the embedded roles data
	// in the native pasteboard — only paste (Cmd+V) does. So before every drag we
	// silently paste a 1-frame stub with the Captions role and immediately undo it.
	// This forces FCP to register the role in the library, after which the native
	// drag works fine. Hacky but there's no public API to create roles.
	private func ensureCaptionRoleExists(then completion: @escaping () -> Void) {
		let pb = NSPasteboard.general
		pb.clearContents()
		pb.setData(Self.roleBootstrapStub, forType: proFFPasteboardType)

		let src = CGEventSource(stateID: .hidSystemState)

		let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
		vDown?.flags = .maskCommand
		let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
		vUp?.flags = .maskCommand
		vDown?.post(tap: .cghidEventTap)
		vUp?.post(tap: .cghidEventTap)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
			let zDown = CGEvent(keyboardEventSource: src, virtualKey: 0x06, keyDown: true)
			zDown?.flags = .maskCommand
			let zUp = CGEvent(keyboardEventSource: src, virtualKey: 0x06, keyDown: false)
			zUp?.flags = .maskCommand
			zDown?.post(tap: .cghidEventTap)
			zUp?.post(tap: .cghidEventTap)

			DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
				completion()
			}
		}
	}

	private static let roleBootstrapStub: Data = {
		let bundlePath = Bundle(for: FCPDragSourceView.self)
			.url(forResource: "BasicTitleTemplate", withExtension: "plist")!
		let templateData = try! Data(contentsOf: bundlePath)
		var plist =
			try! PropertyListSerialization.propertyList(
				from: templateData, options: .mutableContainersAndLeaves, format: nil
			) as! [String: Any]
		let objData = plist["ffpasteboardobject"] as! Data
		var archive =
			try! PropertyListSerialization.propertyList(
				from: objData, options: .mutableContainersAndLeaves, format: nil
			) as! [String: Any]
		var objects = archive["$objects"] as! [Any]
		// Set Captions subrole UUID
		objects[59] = "VaUwsjFSHS5Cpf3PuyPV0Cw"
		// Minimal duration: 1 frame
		objects[8] = "{(0/1),(1001/24000)}"
		objects[13] = "{(21600000/6000),(1001/24000)}"
		objects[19] = "{(21600000/6000),(1001/24000)}"
		archive["$objects"] = objects
		let newObjData = try! PropertyListSerialization.data(
			fromPropertyList: archive, format: .binary, options: 0)
		plist["ffpasteboardobject"] = newObjData
		return try! PropertyListSerialization.data(
			fromPropertyList: plist, format: .binary, options: 0)
	}()

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
