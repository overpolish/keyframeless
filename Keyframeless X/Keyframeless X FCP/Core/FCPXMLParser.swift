/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// FCPXML reader for Keyframeless X.
///
/// The implementation is split across this folder:
/// - `FCPXMLParser+Models.swift` - data types (AudioClip, AudioFilter, etc.)
/// - `FCPXMLParser+Time.swift` - time and offset parsing helpers
/// - `FCPXMLParser+Adjustments.swift` - `<adjust-volume>`, `<filter-audio>`,
///   `<audio-channel-source>`, unhandled-adjustment detection
/// - `FCPXMLParser+Walk.swift` - recursive timeline walk producing `AudioClip`s
/// - `FCPXMLParser.swift` (this file) - top-level entry points
enum FCPXMLParser {

	private static let dialogueClipXPath =
		"asset-clip[starts-with(@audioRole, 'dialogue') and not(audio-channel-source[starts-with(@role, 'effects') and not(@active='0')]) and not(audio-channel-source and not(audio-channel-source[not(@active='0')]))]"

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
			let count = dialogueCount(in: el, resources: resources)
			return DropItem(name: name, kind: kind, dialogueCount: count)
		}
	}

	private static func dialogueCount(in el: XMLElement, resources: XMLElement?) -> Int {
		switch el.name {
		case "project":
			return projectDialogueCount(el, resources: resources)
		case "asset-clip":
			return isDialogue(el) ? 1 : 0
		case "ref-clip":
			let mediaId = el.attribute(forName: "ref")?.stringValue ?? ""
			let media = resources?.elements(forName: "media").first {
				$0.attribute(forName: "id")?.stringValue == mediaId
			}
			return (try? media?.nodes(forXPath: ".//" + dialogueClipXPath))?.count ?? 0
		case "mc-clip":
			return mcClipDialogueCount(el, resources: resources)
		default:
			return 0
		}
	}

	private static func projectDialogueCount(_ el: XMLElement, resources: XMLElement?) -> Int {
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
		let mcClips =
			(try? el.nodes(forXPath: ".//mc-clip"))?
			.compactMap { $0 as? XMLElement } ?? []
		for mcClip in mcClips {
			projectCount += mcClipDialogueCount(mcClip, resources: resources)
		}
		return projectCount
	}

	private static func mcClipDialogueCount(_ mcClip: XMLElement, resources: XMLElement?) -> Int {
		let mcMediaId = mcClip.attribute(forName: "ref")?.stringValue ?? ""
		let mcMedia = resources?.elements(forName: "media").first {
			$0.attribute(forName: "id")?.stringValue == mcMediaId
		}
		guard let multicam = mcMedia?.elements(forName: "multicam").first else { return 0 }
		let activeAngles = audioAngleIDs(from: mcClip)
		var count = 0
		for angle in multicam.elements(forName: "mc-angle") {
			if let activeAngles {
				let angleID = angle.attribute(forName: "angleID")?.stringValue ?? ""
				guard activeAngles.contains(angleID) else { continue }
			}
			count += (try? angle.nodes(forXPath: ".//" + dialogueClipXPath))?.count ?? 0
		}
		return count
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
		let topMcClips =
			doc.rootElement()?.children?.compactMap { $0 as? XMLElement }
			.filter { $0.name == "mc-clip" } ?? []

		let formatId = resolveFormatId(
			seq: seq, topClips: topClips, topRefClips: topRefClips, topMcClips: topMcClips,
			resources: resources)

		guard
			let format = resources?.elements(forName: "format").first(where: {
				$0.attribute(forName: "id")?.stringValue == formatId
			})
		else { return nil }

		let duration = resolveSequenceDuration(
			seq: seq, topClips: topClips, topRefClips: topRefClips, topMcClips: topMcClips)

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

	// Resolve format ID: project sequence → direct clip → compound clip → multicam clip
	private static func resolveFormatId(
		seq: XMLElement?, topClips: [XMLElement], topRefClips: [XMLElement],
		topMcClips: [XMLElement], resources: XMLElement?
	) -> String {
		if let id = seq?.attribute(forName: "format")?.stringValue { return id }
		if let id = topClips.first?.attribute(forName: "format")?.stringValue { return id }
		if let refClip = topRefClips.first,
			let mediaId = refClip.attribute(forName: "ref")?.stringValue,
			let media = resources?.elements(forName: "media").first(where: {
				$0.attribute(forName: "id")?.stringValue == mediaId
			}),
			let mediaSeq = media.elements(forName: "sequence").first,
			let id = mediaSeq.attribute(forName: "format")?.stringValue
		{
			return id
		}
		if let mcClip = topMcClips.first,
			let mediaId = mcClip.attribute(forName: "ref")?.stringValue,
			let media = resources?.elements(forName: "media").first(where: {
				$0.attribute(forName: "id")?.stringValue == mediaId
			}),
			let multicam = media.elements(forName: "multicam").first,
			let id = multicam.attribute(forName: "format")?.stringValue
		{
			return id
		}
		return "r1"
	}

	private static func resolveSequenceDuration(
		seq: XMLElement?, topClips: [XMLElement], topRefClips: [XMLElement],
		topMcClips: [XMLElement]
	) -> Double {
		if let seq {
			return parseTime(seq.attribute(forName: "duration")?.stringValue ?? "0s")
		}
		if !topClips.isEmpty {
			return
				topClips
				.compactMap { $0.attribute(forName: "duration")?.stringValue }
				.map { parseTime($0) }
				.reduce(0, +)
		}
		if let refClip = topRefClips.first {
			return parseTime(refClip.attribute(forName: "duration")?.stringValue ?? "0s")
		}
		if let mcClip = topMcClips.first {
			return parseTime(mcClip.attribute(forName: "duration")?.stringValue ?? "0s")
		}
		return 0
	}

	static func audioClips(in doc: XMLDocument) -> [AudioClip] {
		let assets = assetResources(in: doc)
		let effects = parseAudioEffectResources(in: doc)
		let resources = doc.rootElement()?.elements(forName: "resources").first

		var mediaMap: [String: XMLElement] = [:]
		var multicamMap: [String: XMLElement] = [:]
		for media in resources?.elements(forName: "media") ?? [] {
			guard let id = media.attribute(forName: "id")?.stringValue else { continue }
			if let seq = media.elements(forName: "sequence").first { mediaMap[id] = seq }
			if let multicam = media.elements(forName: "multicam").first {
				multicamMap[id] = multicam
			}
		}

		var clips: [AudioClip] = []
		let topLevel =
			doc.rootElement()?.children?.compactMap { $0 as? XMLElement }
			.filter { $0.name != "resources" } ?? []

		for el in topLevel {
			collectAudioClips(
				from: el, assets: assets, mediaMap: mediaMap, multicamMap: multicamMap,
				effects: effects, into: &clips)
		}
		return clips
	}

	private static func collectAudioClips(
		from el: XMLElement, assets: [String: AssetResource],
		mediaMap: [String: XMLElement], multicamMap: [String: XMLElement],
		effects: [String: AudioEffectResource], into clips: inout [AudioClip]
	) {
		switch el.name {
		case "project":
			guard let seq = el.elements(forName: "sequence").first,
				let spine = seq.elements(forName: "spine").first
			else { return }
			let tcStart = parseTime(seq.attribute(forName: "tcStart")?.stringValue ?? "0s")
			walkElement(
				spine, tcStart: tcStart, compound: nil, assets: assets, mediaMap: mediaMap,
				multicamMap: multicamMap, effects: effects, into: &clips)
		case "ref-clip":
			guard isEnabled(el) else { return }
			walkElement(
				el, tcStart: 0, compound: nil, assets: assets, mediaMap: mediaMap,
				multicamMap: multicamMap, effects: effects, into: &clips)
			if let mediaId = el.attribute(forName: "ref")?.stringValue,
				let mediaSeq = mediaMap[mediaId],
				let mediaSpine = mediaSeq.elements(forName: "spine").first
			{
				let mediaTcStart = parseTime(
					mediaSeq.attribute(forName: "tcStart")?.stringValue ?? "0s")
				walkElement(
					mediaSpine, tcStart: mediaTcStart, compound: nil, assets: assets,
					mediaMap: mediaMap, multicamMap: multicamMap, effects: effects,
					into: &clips)
			}
		case "mc-clip":
			guard isEnabled(el),
				let mediaId = el.attribute(forName: "ref")?.stringValue,
				let multicam = multicamMap[mediaId]
			else { return }
			let activeAngles = audioAngleIDs(from: el)
			let mcTcStart = parseTime(
				multicam.attribute(forName: "tcStart")?.stringValue ?? "0s")
			let mcDuration = parseTime(
				el.attribute(forName: "duration")?.stringValue ?? "0s")
			let trimStart = parseTime(
				el.attribute(forName: "start")?.stringValue
					?? multicam.attribute(forName: "tcStart")?.stringValue ?? "0s")
			let ctx = CompoundContext(
				mainOffset: 0,
				internalStart: trimStart - mcTcStart,
				internalEnd: trimStart - mcTcStart + mcDuration,
				tcStart: mcTcStart
			)
			for angle in multicam.elements(forName: "mc-angle") {
				if let activeAngles {
					let angleID = angle.attribute(forName: "angleID")?.stringValue ?? ""
					guard activeAngles.contains(angleID) else { continue }
				}
				walkElement(
					angle, tcStart: mcTcStart, compound: ctx, assets: assets,
					mediaMap: mediaMap, multicamMap: multicamMap, effects: effects,
					into: &clips)
			}
		case "asset-clip":
			if isEnabled(el), isDialogue(el), !isMuted(el) {
				clips.append(
					makeClip(from: el, assets: assets, tcStart: nil, effects: effects))
			}
		default:
			return
		}
	}
}
