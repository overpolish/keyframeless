/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension FCPXMLParser {

	/// FCP-private adjustments we can't reproduce client-side (no public AU
	/// or daemon entry point). We surface them in the UI so users know
	/// captions won't reflect them.
	static let unhandledAdjustmentNames: Set<String> = [
		"adjust-voiceIsolation",
		"adjust-loudness",
		"adjust-noiseReduction",
		"adjust-humReduction",
		"adjust-matchEQ",
	]

	static func isDialogue(_ el: XMLElement) -> Bool {
		let channelSources = el.elements(forName: "audio-channel-source")
		let activeSources = channelSources.filter {
			$0.attribute(forName: "active")?.stringValue != "0"
		}
		// Channel-sources present but all inactive: audio is disabled on this clip.
		if !channelSources.isEmpty && activeSources.isEmpty { return false }
		let topRole = el.attribute(forName: "audioRole")?.stringValue ?? ""
		// An active `audio-channel-source` with an explicit `role` reassigns that
		// channel's role, overriding the clip's top-level `audioRole` (which often
		// lingers as a stale import default). Only trust `audioRole` when no active
		// channel-source specifies a role - e.g. a music clip reassigned via
		// `<audio-channel-source role="music.music-1"/>` must not read as dialogue
		// just because `audioRole="dialogue"` was never cleared.
		let channelRoles = activeSources.compactMap {
			$0.attribute(forName: "role")?.stringValue
		}.filter { !$0.isEmpty }
		let effectiveRoles = channelRoles.isEmpty ? [topRole] : channelRoles
		guard effectiveRoles.contains(where: { $0.hasPrefix("dialogue") }) else { return false }
		return !effectiveRoles.contains(where: { $0.hasPrefix("effects") })
	}

	/// Ref-clips can disable a contained subrole via `<audio-role-source role="..." active="0"/>`.
	/// Returns true when dialogue is explicitly disabled at this wrapper level.
	static func isDialogueRoleDisabled(_ el: XMLElement) -> Bool {
		let sources = el.elements(forName: "audio-role-source")
		guard !sources.isEmpty else { return false }
		let dialogueSources = sources.filter {
			($0.attribute(forName: "role")?.stringValue ?? "").hasPrefix("dialogue")
		}
		guard !dialogueSources.isEmpty else { return false }
		return dialogueSources.allSatisfy {
			$0.attribute(forName: "active")?.stringValue == "0"
		}
	}

	static func isMuted(_ el: XMLElement) -> Bool {
		guard let adjustVolume = el.elements(forName: "adjust-volume").first else {
			return false
		}
		if let param = adjustVolume.elements(forName: "param").first(where: {
			$0.attribute(forName: "name")?.stringValue == "amount"
		}) {
			let keyframes =
				param.elements(forName: "keyframeAnimation").first?
				.elements(forName: "keyframe") ?? []
			if !keyframes.isEmpty {
				return keyframes.allSatisfy {
					parseVolume($0.attribute(forName: "value")?.stringValue ?? "0dB") <= -96
				}
			}
		}
		return parseVolume(
			adjustVolume.attribute(forName: "amount")?.stringValue ?? "0dB") <= -96
	}

	static func parseAudioEffectResources(in doc: XMLDocument) -> [String: AudioEffectResource] {
		var map: [String: AudioEffectResource] = [:]
		let resources = doc.rootElement()?.elements(forName: "resources").first
		for effect in resources?.elements(forName: "effect") ?? [] {
			guard let id = effect.attribute(forName: "id")?.stringValue,
				let uid = effect.attribute(forName: "uid")?.stringValue
			else { continue }
			let prefix = "AudioUnit: 0x"
			guard uid.hasPrefix(prefix) else { continue }
			let hex = String(uid.dropFirst(prefix.count))
			guard hex.count == 24 else { continue }
			func osType(_ s: Substring) -> UInt32? { UInt32(s, radix: 16) }
			guard let t = osType(hex.prefix(8)),
				let st = osType(hex.dropFirst(8).prefix(8)),
				let mf = osType(hex.dropFirst(16).prefix(8))
			else { continue }
			let name = effect.attribute(forName: "name")?.stringValue ?? ""
			map[id] = AudioEffectResource(
				auType: t, auSubtype: st, auManufacturer: mf, name: name)
		}
		return map
	}

	static func parseAudioFilters(
		_ el: XMLElement, effects: [String: AudioEffectResource]
	) -> [AudioFilter]? {
		let filters = el.elements(forName: "filter-audio")
		guard !filters.isEmpty else { return nil }
		var result: [AudioFilter] = []
		for f in filters {
			if f.attribute(forName: "enabled")?.stringValue == "0" { continue }
			guard let ref = f.attribute(forName: "ref")?.stringValue,
				let eff = effects[ref]
			else { continue }
			let stateB64 = f.elements(forName: "data")
				.first(where: { $0.attribute(forName: "key")?.stringValue == "effectState" })?
				.stringValue?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			let state = stateB64.flatMap {
				Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
			}
			let overrides = parseParamOverrides(in: f)
			result.append(
				AudioFilter(
					auType: eff.auType,
					auSubtype: eff.auSubtype,
					auManufacturer: eff.auManufacturer,
					name: f.attribute(forName: "name")?.stringValue ?? eff.name,
					effectState: state,
					paramOverrides: overrides
				))
		}
		return result.isEmpty ? nil : result
	}

	private static func parseParamOverrides(in filter: XMLElement)
		-> [AudioFilter.ParamOverride]
	{
		filter.elements(forName: "param").compactMap { p in
			guard let keyStr = p.attribute(forName: "key")?.stringValue,
				let key = UInt32(keyStr)
			else { return nil }
			if let kfa = p.elements(forName: "keyframeAnimation").first {
				let kfs: [AudioFilter.ParamOverride.Keyframe] = kfa.elements(
					forName: "keyframe"
				).compactMap { kf in
					guard let t = kf.attribute(forName: "time")?.stringValue,
						let v = kf.attribute(forName: "value")?.stringValue,
						let val = Float(v)
					else { return nil }
					return AudioFilter.ParamOverride.Keyframe(
						time: parseTime(t), value: val)
				}.sorted { $0.time < $1.time }
				if let first = kfs.first {
					return AudioFilter.ParamOverride(
						key: key, value: first.value, keyframes: kfs)
				}
			}
			if let valStr = p.attribute(forName: "value")?.stringValue,
				let val = Float(valStr)
			{
				return AudioFilter.ParamOverride(key: key, value: val, keyframes: nil)
			}
			return nil
		}
	}

	static func detectUnhandledAdjustments(_ el: XMLElement) -> [String]? {
		var found: Set<String> = []
		func walk(_ node: XMLElement) {
			if let n = node.name, unhandledAdjustmentNames.contains(n) {
				found.insert(n)
			}
			for child in node.children?.compactMap({ $0 as? XMLElement }) ?? [] {
				walk(child)
			}
		}
		walk(el)
		return found.isEmpty ? nil : found.sorted()
	}

	static func parseActiveSourceChannels(_ el: XMLElement) -> [Int]? {
		let sources = el.elements(forName: "audio-channel-source")
		guard !sources.isEmpty else { return nil }
		var picked: [Int] = []
		for src in sources {
			if src.attribute(forName: "active")?.stringValue == "0" { continue }
			let srcCh = src.attribute(forName: "srcCh")?.stringValue ?? ""
			for part in srcCh.split(separator: ",") {
				if let n = Int(part.trimmingCharacters(in: .whitespaces)) {
					picked.append(n)
				}
			}
		}
		return picked.isEmpty ? nil : picked
	}

	static func parseFades(_ el: XMLElement) -> (FadeSpec?, FadeSpec?) {
		guard let adjustVolume = el.elements(forName: "adjust-volume").first else {
			return (nil, nil)
		}
		// fadeIn/fadeOut may be direct children of adjust-volume, or nested in
		// <param name="amount">.
		var container: XMLElement = adjustVolume
		if let param = adjustVolume.elements(forName: "param").first(where: {
			$0.attribute(forName: "name")?.stringValue == "amount"
		}),
			param.elements(forName: "fadeIn").first != nil
				|| param.elements(forName: "fadeOut").first != nil
		{
			container = param
		}
		func parse(_ name: String) -> FadeSpec? {
			guard let e = container.elements(forName: name).first,
				let d = e.attribute(forName: "duration")?.stringValue
			else { return nil }
			let dur = parseTime(d)
			guard dur > 0 else { return nil }
			let type = e.attribute(forName: "type")?.stringValue ?? "linear"
			return FadeSpec(duration: dur, type: type)
		}
		return (parse("fadeIn"), parse("fadeOut"))
	}

	static func parseVolumeCurve(_ el: XMLElement) -> [VolumePoint]? {
		guard let adjustVolume = el.elements(forName: "adjust-volume").first else { return nil }
		if let param = adjustVolume.elements(forName: "param").first(where: {
			$0.attribute(forName: "name")?.stringValue == "amount"
		}),
			let kfa = param.elements(forName: "keyframeAnimation").first
		{
			let points: [VolumePoint] = kfa.elements(forName: "keyframe").compactMap { kf in
				guard let t = kf.attribute(forName: "time")?.stringValue,
					let v = kf.attribute(forName: "value")?.stringValue
				else { return nil }
				return VolumePoint(time: parseTime(t), dB: parseVolume(v))
			}.sorted { $0.time < $1.time }
			if !points.isEmpty { return points }
		}
		let amount = adjustVolume.attribute(forName: "amount")?.stringValue ?? "0dB"
		let dB = parseVolume(amount)
		if dB == 0 { return nil }
		return [VolumePoint(time: 0, dB: dB)]
	}

	static func parseVolume(_ s: String) -> Double {
		Double(s.replacingOccurrences(of: "dB", with: "")) ?? 0
	}
}
