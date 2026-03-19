/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

enum FCPXMLParser {

	private static let dialogueClipXPath =
		"asset-clip[starts-with(@audioRole, 'dialogue') and not(audio-channel-source[starts-with(@role, 'effects')])]"

	struct DropItem {
		let name: String
		let kind: String
		let dialogueCount: Int
	}

	static func isDeniedDrop(in doc: XMLDocument) -> Bool {
		let children = doc.rootElement()?.children?.compactMap { $0 as? XMLElement } ?? []
		return children.contains { $0.name == "library" || $0.name == "event" }
	}

	static func topLevelItems(in doc: XMLDocument) -> [DropItem] {
		let resources = doc.rootElement()?.elements(forName: "resources").first
		let children = doc.rootElement()?.children?.compactMap { $0 as? XMLElement } ?? []
		return children.filter { $0.name != "resources" }.map { el in
			let name = el.attribute(forName: "name")?.stringValue ?? el.name ?? "?"
			let kind = el.name ?? "?"
			let count: Int
			switch el.name {
			case "project":
				var projectCount = (try? el.nodes(forXPath: ".//" + dialogueClipXPath))?.count ?? 0
				let refIds =
					(try? el.nodes(forXPath: ".//ref-clip/@ref"))?
					.compactMap { $0.stringValue } ?? []
				for mediaId in refIds {
					let media = resources?.elements(forName: "media").first {
						$0.attribute(forName: "id")?.stringValue == mediaId
					}
					projectCount +=
						(try? media?.nodes(forXPath: ".//" + dialogueClipXPath))?.count ?? 0
				}
				count = projectCount
			case "asset-clip":
				let role = el.attribute(forName: "audioRole")?.stringValue ?? ""
				let hasEffects = el.elements(forName: "audio-channel-source").contains {
					$0.attribute(forName: "role")?.stringValue?.hasPrefix("effects") ?? false
				}
				count = role.hasPrefix("dialogue") && !hasEffects ? 1 : 0
			case "ref-clip":
				let mediaId = el.attribute(forName: "ref")?.stringValue ?? ""
				let media = resources?.elements(forName: "media").first {
					$0.attribute(forName: "id")?.stringValue == mediaId
				}
				count = (try? media?.nodes(forXPath: ".//" + dialogueClipXPath))?.count ?? 0
			default:
				count = 0
			}
			return DropItem(name: name, kind: kind, dialogueCount: count)
		}
	}

	struct ProjectFormat {
		static let `default` = ProjectFormat(
			name: "FFVideoFormat1080p60",
			frameDuration: "100/6000s",
			width: 1920,
			height: 1080,
			sequenceDuration: 0
		)

		let name: String
		let frameDuration: String
		let width: Int
		let height: Int
		let sequenceDuration: Double

		private var fps: Double? {
			let raw =
				frameDuration.hasSuffix("s") ? String(frameDuration.dropLast()) : frameDuration
			guard !raw.isEmpty else { return nil }
			if let slash = raw.firstIndex(of: "/") {
				let num = Double(raw[raw.startIndex..<slash]) ?? 1
				let den = Double(raw[raw.index(after: slash)...]) ?? 1
				return num > 0 ? den / num : nil
			}
			return Double(raw)
		}

		var fpsDisplay: String {
			guard let fps else { return "" }
			return fps.truncatingRemainder(dividingBy: 1) == 0
				? "\(Int(fps)) fps"
				: String(format: "%.2f fps", fps)
		}

		var durationDisplay: String { timecode(for: sequenceDuration) }

		func timecode(for seconds: Double) -> String {
			guard let fps, fps > 0 else {
				return String(format: "%.2fs", seconds)
			}
			let roundedFps = Int(fps.rounded())
			let totalFrames = Int(round(seconds * fps))
			let ff = totalFrames % roundedFps
			let totalSecs = totalFrames / roundedFps
			let ss = totalSecs % 60
			let mm = (totalSecs / 60) % 60
			let hh = totalSecs / 3600
			if hh > 0 {
				return String(format: "%d:%02d:%02d:%02d", hh, mm, ss, ff)
			} else if mm > 0 {
				return String(format: "%d:%02d:%02d", mm, ss, ff)
			} else {
				return String(format: "%d:%02d", ss, ff)
			}
		}
	}

	static func projectFormat(in doc: XMLDocument) -> ProjectFormat? {
		let resources = doc.rootElement()?.elements(forName: "resources").first
		let seq = (try? doc.nodes(forXPath: "//project/sequence"))?.first as? XMLElement
		let topClips =
			doc.rootElement()?.children?.compactMap { $0 as? XMLElement }
			.filter { $0.name == "asset-clip" || $0.name == "clip" } ?? []
		let topRefClips =
			doc.rootElement()?.children?.compactMap { $0 as? XMLElement }
			.filter { $0.name == "ref-clip" } ?? []

		// Resolve format ID: project sequence → direct clip → compound clip (ref-clip → media → sequence)
		let formatId: String
		if let id = seq?.attribute(forName: "format")?.stringValue {
			formatId = id
		} else if let id = topClips.first?.attribute(forName: "format")?.stringValue {
			formatId = id
		} else if let refClip = topRefClips.first,
			let mediaId = refClip.attribute(forName: "ref")?.stringValue,
			let media = resources?.elements(forName: "media").first(where: {
				$0.attribute(forName: "id")?.stringValue == mediaId
			}),
			let mediaSeq = media.elements(forName: "sequence").first,
			let id = mediaSeq.attribute(forName: "format")?.stringValue
		{
			formatId = id
		} else {
			formatId = "r1"
		}

		guard
			let format = resources?.elements(forName: "format").first(where: {
				$0.attribute(forName: "id")?.stringValue == formatId
			})
		else { return nil }

		let duration: Double
		if let seq {
			duration = parseTime(seq.attribute(forName: "duration")?.stringValue ?? "0s")
		} else if !topClips.isEmpty {
			duration =
				topClips
				.compactMap { $0.attribute(forName: "duration")?.stringValue }
				.map { parseTime($0) }
				.reduce(0, +)
		} else if let refClip = topRefClips.first {
			duration = parseTime(refClip.attribute(forName: "duration")?.stringValue ?? "0s")
		} else {
			duration = 0
		}

		let name = format.attribute(forName: "name")?.stringValue ?? ""
		let width = Int(format.attribute(forName: "width")?.stringValue ?? "") ?? 0
		let height = Int(format.attribute(forName: "height")?.stringValue ?? "") ?? 0
		let isUsable =
			width > 0 && height > 0 && !name.localizedCaseInsensitiveContains("undefined")
		return ProjectFormat(
			name: isUsable ? name : ProjectFormat.default.name,
			frameDuration: isUsable
				? (format.attribute(forName: "frameDuration")?.stringValue ?? "")
				: ProjectFormat.default.frameDuration,
			width: isUsable ? width : ProjectFormat.default.width,
			height: isUsable ? height : ProjectFormat.default.height,
			sequenceDuration: duration
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
		let resources = doc.rootElement()?.elements(forName: "resources").first

		var mediaMap: [String: XMLElement] = [:]
		for media in resources?.elements(forName: "media") ?? [] {
			guard let id = media.attribute(forName: "id")?.stringValue,
				let seq = media.elements(forName: "sequence").first
			else { continue }
			mediaMap[id] = seq
		}

		var clips: [AudioClip] = []
		let topLevel =
			doc.rootElement()?.children?.compactMap { $0 as? XMLElement }
			.filter { $0.name != "resources" } ?? []

		for el in topLevel {
			switch el.name {
			case "project":
				guard let seq = el.elements(forName: "sequence").first,
					let spine = seq.elements(forName: "spine").first
				else { continue }
				let tcStart = parseTime(seq.attribute(forName: "tcStart")?.stringValue ?? "0s")
				walkElement(
					spine, tcStart: tcStart, compound: nil, assets: assets, mediaMap: mediaMap,
					into: &clips)
			case "ref-clip":
				guard isEnabled(el) else { continue }
				walkElement(
					el, tcStart: 0, compound: nil, assets: assets, mediaMap: mediaMap,
					into: &clips)
				if let mediaId = el.attribute(forName: "ref")?.stringValue,
					let mediaSeq = mediaMap[mediaId],
					let mediaSpine = mediaSeq.elements(forName: "spine").first
				{
					let mediaTcStart = parseTime(
						mediaSeq.attribute(forName: "tcStart")?.stringValue ?? "0s")
					walkElement(
						mediaSpine, tcStart: mediaTcStart, compound: nil, assets: assets,
						mediaMap: mediaMap, into: &clips)
				}
			case "asset-clip":
				if isEnabled(el), isDialogue(el) {
					clips.append(makeClip(from: el, assets: assets, tcStart: nil))
				}
			default:
				break
			}
		}

		return clips
	}

	private static func isEnabled(_ el: XMLElement) -> Bool {
		el.attribute(forName: "enabled")?.stringValue != "0"
	}

	private static func isDialogue(_ el: XMLElement) -> Bool {
		guard (el.attribute(forName: "audioRole")?.stringValue ?? "").hasPrefix("dialogue")
		else { return false }
		return !el.elements(forName: "audio-channel-source").contains {
			($0.attribute(forName: "role")?.stringValue ?? "").hasPrefix("effects")
		}
	}

	// Carries the mapping context when walking inside a compound clip's media spine.
	// mainOffset: where the ref-clip starts in the main timeline
	// internalStart/End: the trimmed window in the compound clip's time space (tcStart-relative)
	// tcStart: the compound sequence's tcStart, used to normalise clip offsets
	private struct CompoundContext {
		let mainOffset: Double
		let internalStart: Double
		let internalEnd: Double
		let tcStart: Double
	}

	private static func walkElement(
		_ el: XMLElement, tcStart: Double, compound: CompoundContext?,
		assets: [String: AssetResource], mediaMap: [String: XMLElement],
		into clips: inout [AudioClip]
	) {
		for child in el.children?.compactMap({ $0 as? XMLElement }) ?? [] {
			if child.name == "asset-clip", isEnabled(child), isDialogue(child) {
				if let ctx = compound {
					// Position in compound's time space (tcStart-relative), walking the full
					// parent chain so nested containers (e.g. video → secondary spine → clip)
					// are resolved correctly rather than reading just the raw offset attribute.
					let internalOffset = projectTime(of: child, tcStart: ctx.tcStart)
					let clipDur = parseTime(
						child.attribute(forName: "duration")?.stringValue ?? "0s")
					// Skip if entirely outside the trimmed window
					guard internalOffset < ctx.internalEnd,
						internalOffset + clipDur > ctx.internalStart
					else { continue }
					// Clamp to the visible window
					let visibleStart = max(internalOffset, ctx.internalStart)
					let visibleEnd = min(internalOffset + clipDur, ctx.internalEnd)
					let mainStart = ctx.mainOffset + (visibleStart - ctx.internalStart)
					let ref = child.attribute(forName: "ref")?.stringValue
					let asset = ref.flatMap { assets[$0] }
					let clipSourceStart = parseTime(
						child.attribute(forName: "start")?.stringValue ?? "0s")
					clips.append(
						AudioClip(
							name: child.attribute(forName: "name")?.stringValue ?? "clip",
							start: mainStart,
							end: mainStart + (visibleEnd - visibleStart),
							sourceStart: clipSourceStart - (asset?.mediaStart ?? 0),
							sourceDuration: visibleEnd - visibleStart,
							url: asset?.url,
							bookmark: asset?.bookmark
						))
				} else {
					clips.append(makeClip(from: child, assets: assets, tcStart: tcStart))
				}
			} else if child.name == "ref-clip", isEnabled(child) {
				// Connected clips (XML children of the ref-clip) are in the main XML tree;
				// projectTime works for them as-is.
				walkElement(
					child, tcStart: tcStart, compound: nil, assets: assets, mediaMap: mediaMap,
					into: &clips)
				// Recurse into compound clip's media spine with explicit position + trim context.
				if let mediaId = child.attribute(forName: "ref")?.stringValue,
					let mediaSeq = mediaMap[mediaId],
					let mediaSpine = mediaSeq.elements(forName: "spine").first
				{
					let mediaTcStart = parseTime(
						mediaSeq.attribute(forName: "tcStart")?.stringValue ?? "0s")
					let refTrimStart = parseTime(
						child.attribute(forName: "start")?.stringValue ?? "0s")
					let refDuration = parseTime(
						child.attribute(forName: "duration")?.stringValue ?? "0s")
					let refMainOffset = projectTime(of: child, tcStart: tcStart)
					let ctx = CompoundContext(
						mainOffset: refMainOffset,
						internalStart: refTrimStart - mediaTcStart,
						internalEnd: refTrimStart - mediaTcStart + refDuration,
						tcStart: mediaTcStart
					)
					walkElement(
						mediaSpine, tcStart: mediaTcStart, compound: ctx, assets: assets,
						mediaMap: mediaMap, into: &clips)
				}
			} else {
				walkElement(
					child, tcStart: tcStart, compound: compound, assets: assets,
					mediaMap: mediaMap, into: &clips)
			}
		}
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
		guard let parent = el.parent as? XMLElement else { return offset - tcStart }
		// Primary spine (no lane) and sequence use sequence-absolute offsets — stop here
		let isPrimaryContainer =
			parent.name == "sequence"
			|| (parent.name == "spine" && parent.attribute(forName: "lane") == nil)
		guard !isPrimaryContainer else { return offset - tcStart }
		// Secondary storylines (spine with lane) have storyline-relative offsets,
		// so continue climbing like any other container.
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
