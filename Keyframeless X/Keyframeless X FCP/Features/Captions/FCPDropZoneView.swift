/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import SwiftUI

struct FCPDropZoneView: NSViewRepresentable {
	var onDrop: (String) -> Void

	func makeNSView(context: Context) -> FCPDropTargetView {
		let view = FCPDropTargetView()
		view.onDrop = onDrop
		return view
	}

	func updateNSView(_ nsView: FCPDropTargetView, context: Context) {
		nsView.onDrop = onDrop
	}
}

class FCPDropTargetView: NSView {
	var onDrop: ((String) -> Void)?

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
			do {
				let doc = try XMLDocument(data: data, options: [])
				onDrop?(summarize(doc))
			} catch {
				onDrop?("Parse error: \(error.localizedDescription)")
			}
			return true
		}
		return false
	}

	private func summarize(_ doc: XMLDocument) -> String {
		let events = (try? doc.nodes(forXPath: "//event"))?.count ?? 0
		let clips = (try? doc.nodes(forXPath: "//clip"))?.count ?? 0
		let assetClips = (try? doc.nodes(forXPath: "//asset-clip"))?.count ?? 0
		return "\(events) event(s), \(clips + assetClips) clip(s)"
	}
}
