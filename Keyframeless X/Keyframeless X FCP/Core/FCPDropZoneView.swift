/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import SwiftUI

struct FCPDropZoneView: NSViewRepresentable {
	var onDrop: ([FCPXMLParser.AudioClip]) -> Void
	var onFormat: (FCPXMLParser.ProjectFormat) -> Void
	var onItems: ([FCPXMLParser.DropItem]) -> Void
	var onDenied: () -> Void
	var onTargeted: (Bool) -> Void

	func makeNSView(context: Context) -> FCPDropTargetView {
		let view = FCPDropTargetView()
		view.onDrop = onDrop
		view.onFormat = onFormat
		view.onItems = onItems
		view.onDenied = onDenied
		view.onTargeted = onTargeted
		return view
	}

	func updateNSView(_ nsView: FCPDropTargetView, context: Context) {
		nsView.onDrop = onDrop
		nsView.onFormat = onFormat
		nsView.onItems = onItems
		nsView.onDenied = onDenied
		nsView.onTargeted = onTargeted
	}
}

class FCPDropTargetView: NSView {
	var onDrop: (([FCPXMLParser.AudioClip]) -> Void)?
	var onFormat: ((FCPXMLParser.ProjectFormat) -> Void)?
	var onItems: (([FCPXMLParser.DropItem]) -> Void)?
	var onDenied: (() -> Void)?
	var onTargeted: ((Bool) -> Void)?

	private let fcpPasteboardTypes: [NSPasteboard.PasteboardType] = [
		"com.apple.finalcutpro.xml.v1-10",
		"com.apple.finalcutpro.xml.v1-9",
		"com.apple.finalcutpro.xml",
	].map { NSPasteboard.PasteboardType($0) }

	override init(frame: NSRect) {
		super.init(frame: frame)
		registerForDraggedTypes(fcpPasteboardTypes)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) not implemented")
	}

	// Passthrough for all mouse events — drag system uses bounds, not hitTest
	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
		let available = sender.draggingPasteboard.types ?? []
		guard fcpPasteboardTypes.contains(where: { available.contains($0) }) else { return [] }
		onTargeted?(true)
		return .copy
	}

	override func draggingExited(_ sender: NSDraggingInfo?) {
		onTargeted?(false)
	}

	override func draggingEnded(_ sender: NSDraggingInfo) {
		onTargeted?(false)
	}

	override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		let pasteboard = sender.draggingPasteboard
		for type in fcpPasteboardTypes {
			guard let available = pasteboard.types, available.contains(type),
				let data = pasteboard.data(forType: type)
			else { continue }
			guard let doc = try? XMLDocument(data: data, options: []) else { return true }
			if FCPXMLParser.isDeniedDrop(in: doc) {
				onDenied?()
				return false
			}
			// TODO should be a callback so its polymorphic
			onDrop?(FCPXMLParser.audioClips(in: doc))
			onItems?(FCPXMLParser.topLevelItems(in: doc))
			onFormat?(FCPXMLParser.projectFormat(in: doc) ?? .default)
			print(doc)
			return true
		}
		return false
	}
}
