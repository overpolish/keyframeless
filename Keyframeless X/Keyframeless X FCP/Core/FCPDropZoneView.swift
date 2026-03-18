/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import SwiftUI

struct FCPDropZoneView: NSViewRepresentable {
	var onDrop: ([FCPXMLParser.AudioClip]) -> Void
	var onFormat: (FCPXMLParser.ProjectFormat) -> Void

	func makeNSView(context: Context) -> FCPDropTargetView {
		let view = FCPDropTargetView()
		view.onDrop = onDrop
		view.onFormat = onFormat
		return view
	}

	func updateNSView(_ nsView: FCPDropTargetView, context: Context) {
		nsView.onDrop = onDrop
		nsView.onFormat = onFormat
	}
}

class FCPDropTargetView: NSView {
	var onDrop: (([FCPXMLParser.AudioClip]) -> Void)?
	var onFormat: ((FCPXMLParser.ProjectFormat) -> Void)?

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

	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
		let available = sender.draggingPasteboard.types ?? []
		return fcpPasteboardTypes.contains(where: { available.contains($0) }) ? .copy : []
	}

	override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		let pasteboard = sender.draggingPasteboard
		for type in fcpPasteboardTypes {
			guard let available = pasteboard.types, available.contains(type),
				let data = pasteboard.data(forType: type)
			else { continue }
			if let doc = try? XMLDocument(data: data, options: []) {
				onDrop?(FCPXMLParser.audioClips(in: doc))
				if let fmt = FCPXMLParser.projectFormat(in: doc) {
					onFormat?(fmt)
				}
			}
			return true
		}
		return false
	}
}
