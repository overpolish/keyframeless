/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension FCPXMLParser {

	static func dialogueAudioRef(_ el: XMLElement) -> String? {
		let audios =
			(try? el.nodes(forXPath: ".//audio"))?.compactMap { $0 as? XMLElement } ?? []
		return audios.first {
			($0.attribute(forName: "role")?.stringValue ?? "").hasPrefix("dialogue")
		}?.attribute(forName: "ref")?.stringValue
	}

	/// Returns the set of angle IDs providing audio in a multicam clip,
	/// or nil when all angles should be used (no explicit mc-source selection).
	static func audioAngleIDs(from mcClip: XMLElement) -> Set<String>? {
		let sources = mcClip.elements(forName: "mc-source")
		guard !sources.isEmpty else { return nil }
		var ids = Set<String>()
		for source in sources {
			let enable = source.attribute(forName: "srcEnable")?.stringValue ?? "all"
			if enable == "all" || enable == "audio" {
				if let angleID = source.attribute(forName: "angleID")?.stringValue {
					ids.insert(angleID)
				}
			}
		}
		return ids.isEmpty ? nil : ids
	}

	static func assetResources(in doc: XMLDocument) -> [String: AssetResource] {
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

	static func makeClip(
		from el: XMLElement, assets: [String: AssetResource], tcStart: Double?,
		effects: [String: AudioEffectResource] = [:]
	) -> AudioClip {
		let ref = el.attribute(forName: "ref")?.stringValue
		let asset = ref.flatMap { assets[$0] }
		let dur = parseTime(el.attribute(forName: "duration")?.stringValue ?? "0s")
		let clipStart = parseTime(el.attribute(forName: "start")?.stringValue ?? "0s")
		let start = tcStart.map { projectTime(of: el, tcStart: $0) } ?? 0
		let (fadeIn, fadeOut) = parseFades(el)
		return AudioClip(
			name: el.attribute(forName: "name")?.stringValue ?? "clip",
			start: start,
			end: start + dur,
			sourceStart: clipStart - (asset?.mediaStart ?? 0),
			sourceDuration: dur,
			url: asset?.url,
			bookmark: asset?.bookmark,
			isCompound: false,
			volumeCurve: parseVolumeCurve(el),
			fadeIn: fadeIn,
			fadeOut: fadeOut,
			auFilters: parseAudioFilters(el, effects: effects),
			sourceChannels: parseActiveSourceChannels(el),
			unhandledAdjustments: detectUnhandledAdjustments(el)
		)
	}

	static func walkElement(
		_ el: XMLElement, tcStart: Double, compound: CompoundContext?,
		assets: [String: AssetResource], mediaMap: [String: XMLElement],
		multicamMap: [String: XMLElement], effects: [String: AudioEffectResource] = [:],
		into clips: inout [AudioClip]
	) {
		for child in el.children?.compactMap({ $0 as? XMLElement }) ?? [] {
			if child.name == "asset-clip", isEnabled(child), isDialogue(child) {
				if !isMuted(child) {
					if let ctx = compound {
						appendCompoundAssetClip(
							child, ctx: ctx, assets: assets, effects: effects,
							fallbackTcStart: tcStart, mediaMap: mediaMap, multicamMap: multicamMap,
							into: &clips)
					} else {
						clips.append(
							makeClip(
								from: child, assets: assets, tcStart: tcStart, effects: effects))
					}
				}
				// Recurse into asset-clip to find nested audio clips even if muted
				walkElement(
					child, tcStart: tcStart, compound: compound, assets: assets,
					mediaMap: mediaMap, multicamMap: multicamMap, effects: effects, into: &clips)
			} else if child.name == "ref-clip", isEnabled(child) {
				// Connected clips (XML children of the ref-clip) are in the main XML tree;
				// projectTime works for them as-is.
				walkElement(
					child, tcStart: tcStart, compound: nil, assets: assets, mediaMap: mediaMap,
					multicamMap: multicamMap, effects: effects, into: &clips)
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
						mediaMap: mediaMap, multicamMap: multicamMap, effects: effects,
						into: &clips)
				}
			} else if child.name == "mc-clip", isEnabled(child) {
				if let mediaId = child.attribute(forName: "ref")?.stringValue,
					let multicam = multicamMap[mediaId]
				{
					let activeAngles = audioAngleIDs(from: child)
					let mcTcStart = parseTime(
						multicam.attribute(forName: "tcStart")?.stringValue ?? "0s")
					let trimStart = parseTime(
						child.attribute(forName: "start")?.stringValue
							?? multicam.attribute(forName: "tcStart")?.stringValue ?? "0s")
					let mcDuration = parseTime(
						child.attribute(forName: "duration")?.stringValue ?? "0s")
					let mcMainOffset = projectTime(of: child, tcStart: tcStart)
					let ctx = CompoundContext(
						mainOffset: mcMainOffset,
						internalStart: trimStart - mcTcStart,
						internalEnd: trimStart - mcTcStart + mcDuration,
						tcStart: mcTcStart
					)
					for angle in multicam.elements(forName: "mc-angle") {
						if let activeAngles {
							let angleID =
								angle.attribute(forName: "angleID")?.stringValue ?? ""
							guard activeAngles.contains(angleID) else { continue }
						}
						walkElement(
							angle, tcStart: mcTcStart, compound: ctx, assets: assets,
							mediaMap: mediaMap, multicamMap: multicamMap, effects: effects,
							into: &clips)
					}
				}
				// Walk mc-clip's own children for connected clips
				walkElement(
					child, tcStart: tcStart, compound: compound, assets: assets,
					mediaMap: mediaMap, multicamMap: multicamMap, effects: effects, into: &clips)
			} else if child.name == "clip", isEnabled(child), !isMuted(child),
				let audioRef = dialogueAudioRef(child)
			{
				appendConnectedClip(
					child, audioRef: audioRef, compound: compound, assets: assets,
					effects: effects, tcStart: tcStart, into: &clips)
				walkElement(
					child, tcStart: tcStart, compound: compound, assets: assets,
					mediaMap: mediaMap, multicamMap: multicamMap, effects: effects, into: &clips)
			} else {
				walkElement(
					child, tcStart: tcStart, compound: compound, assets: assets,
					mediaMap: mediaMap, multicamMap: multicamMap, effects: effects, into: &clips)
			}
		}
	}

	private static func appendCompoundAssetClip(
		_ child: XMLElement, ctx: CompoundContext,
		assets: [String: AssetResource], effects: [String: AudioEffectResource],
		fallbackTcStart: Double,
		mediaMap: [String: XMLElement], multicamMap: [String: XMLElement],
		into clips: inout [AudioClip]
	) {
		let internalOffset = projectTime(of: child, tcStart: ctx.tcStart)
		let clipDur = parseTime(child.attribute(forName: "duration")?.stringValue ?? "0s")
		guard internalOffset < ctx.internalEnd,
			internalOffset + clipDur > ctx.internalStart
		else {
			walkElement(
				child, tcStart: fallbackTcStart, compound: ctx, assets: assets,
				mediaMap: mediaMap, multicamMap: multicamMap, effects: effects, into: &clips)
			return
		}
		let visibleStart = max(internalOffset, ctx.internalStart)
		let visibleEnd = min(internalOffset + clipDur, ctx.internalEnd)
		let mainStart = ctx.mainOffset + (visibleStart - ctx.internalStart)
		let ref = child.attribute(forName: "ref")?.stringValue
		let asset = ref.flatMap { assets[$0] }
		let clipSourceStart = parseTime(child.attribute(forName: "start")?.stringValue ?? "0s")
		let (fadeIn, fadeOut) = parseFades(child)
		clips.append(
			AudioClip(
				name: child.attribute(forName: "name")?.stringValue ?? "clip",
				start: mainStart,
				end: mainStart + (visibleEnd - visibleStart),
				sourceStart: clipSourceStart - (asset?.mediaStart ?? 0),
				sourceDuration: visibleEnd - visibleStart,
				url: asset?.url,
				bookmark: asset?.bookmark,
				isCompound: true,
				volumeCurve: parseVolumeCurve(child),
				fadeIn: fadeIn,
				fadeOut: fadeOut,
				auFilters: parseAudioFilters(child, effects: effects),
				sourceChannels: parseActiveSourceChannels(child),
				unhandledAdjustments: detectUnhandledAdjustments(child)
			))
	}

	private static func appendConnectedClip(
		_ child: XMLElement, audioRef: String,
		compound: CompoundContext?,
		assets: [String: AssetResource], effects: [String: AudioEffectResource],
		tcStart: Double, into clips: inout [AudioClip]
	) {
		let asset = assets[audioRef]
		let dur = parseTime(child.attribute(forName: "duration")?.stringValue ?? "0s")
		let clipStart = parseTime(child.attribute(forName: "start")?.stringValue ?? "0s")
		let (fadeIn, fadeOut) = parseFades(child)
		if let ctx = compound {
			let internalOffset = projectTime(of: child, tcStart: ctx.tcStart)
			guard internalOffset < ctx.internalEnd,
				internalOffset + dur > ctx.internalStart
			else { return }
			let visibleStart = max(internalOffset, ctx.internalStart)
			let visibleEnd = min(internalOffset + dur, ctx.internalEnd)
			let mainStart = ctx.mainOffset + (visibleStart - ctx.internalStart)
			clips.append(
				AudioClip(
					name: child.attribute(forName: "name")?.stringValue ?? "clip",
					start: mainStart,
					end: mainStart + (visibleEnd - visibleStart),
					sourceStart: clipStart - (asset?.mediaStart ?? 0),
					sourceDuration: visibleEnd - visibleStart,
					url: asset?.url,
					bookmark: asset?.bookmark,
					isCompound: true,
					volumeCurve: parseVolumeCurve(child),
					fadeIn: fadeIn,
					fadeOut: fadeOut,
					auFilters: parseAudioFilters(child, effects: effects),
					sourceChannels: parseActiveSourceChannels(child),
					unhandledAdjustments: detectUnhandledAdjustments(child)
				))
		} else {
			let start = projectTime(of: child, tcStart: tcStart)
			clips.append(
				AudioClip(
					name: child.attribute(forName: "name")?.stringValue ?? "clip",
					start: start,
					end: start + dur,
					sourceStart: clipStart - (asset?.mediaStart ?? 0),
					sourceDuration: dur,
					url: asset?.url,
					bookmark: asset?.bookmark,
					isCompound: false,
					volumeCurve: parseVolumeCurve(child),
					fadeIn: fadeIn,
					fadeOut: fadeOut,
					auFilters: parseAudioFilters(child, effects: effects),
					sourceChannels: parseActiveSourceChannels(child),
					unhandledAdjustments: detectUnhandledAdjustments(child)
				))
		}
	}
}
