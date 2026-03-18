/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

enum FCPXMLParser {

	struct ProjectFormat {
		let name: String
		let frameDuration: String
		let width: Int
		let height: Int
	}

	static func projectFormat(in doc: XMLDocument) -> ProjectFormat? {
		let resources = doc.rootElement()?.elements(forName: "resources").first
		guard
			let format = resources?.elements(forName: "format").first(where: {
				$0.attribute(forName: "id")?.stringValue == "r1"
			})
		else { return nil }
		return ProjectFormat(
			name: format.attribute(forName: "name")?.stringValue ?? "",
			frameDuration: format.attribute(forName: "frameDuration")?.stringValue ?? "",
			width: Int(format.attribute(forName: "width")?.stringValue ?? "") ?? 0,
			height: Int(format.attribute(forName: "height")?.stringValue ?? "") ?? 0
		)
	}

	struct AudioClip {
		let name: String
		let start: Double
		let end: Double
		let sourceStart: Double
		let sourceDuration: Double
		let url: URL?
		let bookmark: Data?

		func data() throws -> Data {
			if let bookmark {
				var isStale = false
				if let scopedURL = try? URL(
					resolvingBookmarkData: bookmark,
					options: .withSecurityScope,
					relativeTo: nil,
					bookmarkDataIsStale: &isStale
				) {
					let accessing = scopedURL.startAccessingSecurityScopedResource()
					defer { if accessing { scopedURL.stopAccessingSecurityScopedResource() } }
					return try Data(contentsOf: scopedURL)
				}
			}
			guard let url else { throw CocoaError(.fileNoSuchFile) }
			return try Data(contentsOf: url)
		}
	}

	static func audioClips(in doc: XMLDocument) -> [AudioClip] {
		let assets = assetResources(in: doc)
		var clips: [AudioClip] = []

		let dialogueXPath =
			"asset-clip[starts-with(@audioRole, 'dialogue') and not(audio-channel-source[starts-with(@role, 'effects')])]"

		// Sequence/library drag: clips live inside project > sequence > spine
		for seqNode in (try? doc.nodes(forXPath: "//project/sequence")) ?? [] {
			guard let seq = seqNode as? XMLElement else { continue }
			let tcStart = parseTime(seq.attribute(forName: "tcStart")?.stringValue ?? "0s")
			for clipNode in (try? seq.nodes(forXPath: "spine//" + dialogueXPath)) ?? [] {
				guard let el = clipNode as? XMLElement else { continue }
				clips.append(makeClip(from: el, assets: assets, tcStart: tcStart))
			}
		}

		// Individual clip drag: asset-clips are direct children of <fcpxml> root
		for clipNode in (try? doc.nodes(forXPath: "fcpxml/" + dialogueXPath)) ?? [] {
			guard let el = clipNode as? XMLElement else { continue }
			clips.append(makeClip(from: el, assets: assets, tcStart: nil))
		}

		return clips
	}

	private struct AssetResource {
		let url: URL
		let bookmark: Data?
		let mediaStart: Double
	}

	private static func assetResources(in doc: XMLDocument) -> [String: AssetResource] {
		var map: [String: AssetResource] = [:]
		let resources = doc.rootElement()?.elements(forName: "resources").first
		for asset in resources?.elements(forName: "asset") ?? [] {
			guard let id = asset.attribute(forName: "id")?.stringValue,
				let mediaRep = asset.elements(forName: "media-rep").first,
				let src = mediaRep.attribute(forName: "src")?.stringValue,
				let url = URL(string: src)
			else { continue }
			let bookmarkStr = mediaRep.elements(forName: "bookmark").first?.stringValue?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			map[id] = AssetResource(
				url: url,
				bookmark: bookmarkStr.flatMap {
					Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
				},
				mediaStart: parseTime(asset.attribute(forName: "start")?.stringValue ?? "0s")
			)
		}
		return map
	}

	private static func makeClip(
		from el: XMLElement, assets: [String: AssetResource], tcStart: Double?
	) -> AudioClip {
		let ref = el.attribute(forName: "ref")?.stringValue
		let asset = ref.flatMap { assets[$0] }
		let dur = parseTime(el.attribute(forName: "duration")?.stringValue ?? "0s")
		let clipStart = parseTime(el.attribute(forName: "start")?.stringValue ?? "0s")
		let start = tcStart.map { projectTime(of: el, tcStart: $0) } ?? 0
		return AudioClip(
			name: el.attribute(forName: "name")?.stringValue ?? "clip",
			start: start,
			end: start + dur,
			sourceStart: clipStart - (asset?.mediaStart ?? 0),
			sourceDuration: dur,
			url: asset?.url,
			bookmark: asset?.bookmark
		)
	}

	private static func projectTime(of el: XMLElement, tcStart: Double) -> Double {
		let offset = parseTime(el.attribute(forName: "offset")?.stringValue ?? "0s")
		guard let parent = el.parent as? XMLElement,
			parent.name != "spine", parent.name != "sequence"
		else { return offset - tcStart }
		let parentStart = parseTime(parent.attribute(forName: "start")?.stringValue ?? "0s")
		return projectTime(of: parent, tcStart: tcStart) + (offset - parentStart)
	}

	private static func parseTime(_ s: String) -> Double {
		let raw = s.hasSuffix("s") ? String(s.dropLast()) : s
		if let slash = raw.firstIndex(of: "/") {
			let num = Double(raw[raw.startIndex..<slash]) ?? 0
			let den = Double(raw[raw.index(after: slash)...]) ?? 1
			return num / den
		}
		return Double(raw) ?? 0
	}
}
