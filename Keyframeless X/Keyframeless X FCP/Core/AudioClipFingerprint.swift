/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Stable string identity for an `AudioClip` that changes whenever any
/// processed-audio output would change (source, time range, volume curve,
/// fades, AU filters incl. their params/keyframes, channel routing).
///
/// Used to key processed-audio caches (renderer, waveform) and to detect
/// timeline clip-array changes that should invalidate per-index waveform
/// buffers.
enum AudioClipFingerprint {
	static func of(_ clip: FCPXMLParser.AudioClip) -> String {
		let url = clip.url?.absoluteString ?? clip.name
		return
			"\(url)#\(clip.sourceStart)+\(clip.sourceDuration)"
			+ "/curve=\(volumeCurveHash(clip.volumeCurve))"
			+ "/fade=\(fadeHash(clip.fadeIn))-\(fadeHash(clip.fadeOut))"
			+ "/filters=\(filtersHash(clip.auFilters))"
			+ "/ch=\(channelsHash(clip.sourceChannels))"
	}

	private static func volumeCurveHash(_ points: [FCPXMLParser.VolumePoint]?) -> String {
		points.map { $0.map { "\($0.time)|\($0.dB)" }.joined(separator: ",") } ?? "none"
	}

	private static func fadeHash(_ fade: FCPXMLParser.FadeSpec?) -> String {
		fade.map { "\($0.duration):\($0.type)" } ?? "none"
	}

	private static func channelsHash(_ channels: [Int]?) -> String {
		channels?.map(String.init).joined(separator: ",") ?? "default"
	}

	private static func filtersHash(_ filters: [FCPXMLParser.AudioFilter]?) -> String {
		filters?.map { f in
			let params = f.paramOverrides.map { o -> String in
				let kfs =
					o.keyframes?.map { "\($0.time):\($0.value)" }.joined(separator: ";")
					?? "static"
				return "\(o.key)=\(o.value)/\(kfs)"
			}.joined(separator: ",")
			return "\(f.auType)/\(f.auSubtype)/\(f.auManufacturer)/\(f.effectState?.count ?? 0)/\(params)"
		}.joined(separator: "|") ?? "none"
	}
}
