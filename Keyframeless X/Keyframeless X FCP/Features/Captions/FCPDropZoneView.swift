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
				onDrop?(FCPXMLParser.summarize(doc))
			} catch {
				onDrop?("Parse error: \(error.localizedDescription)")
			}
			return true
		}
		return false
	}
}

struct FCPXMLParser {

	struct AudioClip {
		let name: String
		let start: Double
		let end: Double
	}

	static func summarize(_ doc: XMLDocument) -> String {
		let fps = detectFPS(doc)
		let clips = audioClips(in: doc)
		guard !clips.isEmpty else { return "No audio clips found in sequence" }
		let lines = clips.prefix(5).map {
			"\($0.name): \(timecode($0.start, fps: fps)) → \(timecode($0.end, fps: fps))"
		}
		let suffix = clips.count > 5 ? "\n+ \(clips.count - 5) more" : ""
		return lines.joined(separator: "\n") + suffix
	}

	static func audioClips(in doc: XMLDocument) -> [AudioClip] {
		var clips: [AudioClip] = []
		for seqNode in (try? doc.nodes(forXPath: "//project/sequence")) ?? [] {
			guard let seq = seqNode as? XMLElement else { continue }
			let tcStart = parseTime(seq.attribute(forName: "tcStart")?.stringValue ?? "0s")
			for clipNode
				in (try? seq.nodes(
					forXPath:
						"spine//asset-clip[starts-with(@audioRole, 'dialogue') and not(audio-channel-source[starts-with(@role, 'effects')])]"
				)) ?? []
			{
				guard let el = clipNode as? XMLElement else { continue }
				let name = el.attribute(forName: "name")?.stringValue ?? "clip"
				let start = projectTime(of: el, tcStart: tcStart)
				let dur = parseTime(el.attribute(forName: "duration")?.stringValue ?? "0s")
				clips.append(AudioClip(name: name, start: start, end: start + dur))
			}
		}
		return clips
	}

	static func detectFPS(_ doc: XMLDocument) -> Double {
		let seqFormatID = (try? doc.nodes(forXPath: "//project/sequence/@format"))?.first?
			.stringValue
		let xpath = seqFormatID.map { "//format[@id='\($0)']" } ?? "//format[@frameDuration]"
		guard let el = (try? doc.nodes(forXPath: xpath))?.first as? XMLElement,
			let frameDur = el.attribute(forName: "frameDuration")?.stringValue
		else { return 0 }
		let d = parseTime(frameDur)
		return d > 0 ? 1.0 / d : 0
	}

	static func projectTime(of el: XMLElement, tcStart: Double) -> Double {
		let offset = parseTime(el.attribute(forName: "offset")?.stringValue ?? "0s")
		guard let parent = el.parent as? XMLElement,
			parent.name != "spine", parent.name != "sequence"
		else { return offset - tcStart }
		let parentStart = parseTime(parent.attribute(forName: "start")?.stringValue ?? "0s")
		return projectTime(of: parent, tcStart: tcStart) + (offset - parentStart)
	}

	static func timecode(_ sec: Double, fps: Double) -> String {
		guard fps > 0 else {
			let m = Int(sec) / 60
			let s = sec - Double(m * 60)
			return String(format: "%d:%05.2f", m, s)
		}
		let totalFrames = Int(round(sec * fps))
		let fpsInt = Int(round(fps))
		let ff = totalFrames % fpsInt
		let totalSecs = totalFrames / fpsInt
		let ss = totalSecs % 60
		let mm = (totalSecs / 60) % 60
		let hh = totalSecs / 3600
		return hh > 0
			? String(format: "%d:%02d:%02d:%02d", hh, mm, ss, ff)
			: String(format: "%d:%02d:%02d", mm, ss, ff)
	}

	static func parseTime(_ s: String) -> Double {
		let raw = s.hasSuffix("s") ? String(s.dropLast()) : s
		if let slash = raw.firstIndex(of: "/") {
			let num = Double(raw[raw.startIndex..<slash]) ?? 0
			let den = Double(raw[raw.index(after: slash)...]) ?? 1
			return num / den
		}
		return Double(raw) ?? 0
	}
}
