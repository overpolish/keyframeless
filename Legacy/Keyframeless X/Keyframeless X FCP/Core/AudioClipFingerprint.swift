/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Stable string identity for an `AudioClip` that changes whenever any
/// processed-audio output would change (source, time range, volume curve,
/// fades, AU filters incl. their params/keyframes, channel routing).
///
/// Comes in two flavours, and the difference matters:
///
/// - `of` identifies a clip *on this Mac*, keyed by absolute URL. Used for the
///   processed-audio and waveform caches, and to spot timeline clip-array
///   changes that invalidate per-index waveform buffers.
/// - `identity` identifies the same clip *anywhere*, keyed by filename. Used
///   for Sonar's published-source identity.
///
/// They differ in exactly one requirement: `of` must tell two same-named files
/// in different folders apart, and `identity` must NOT tell two copies of one
/// project on two Macs apart.
enum AudioClipFingerprint {
	/// Local identity. Absolute URL, so two same-named files can't collide in a
	/// cache and hand back each other's audio.
	static func of(_ clip: FCPXMLParser.AudioClip) -> String {
		(clip.url?.absoluteString ?? clip.name) + edits(clip)
	}

	/// Portable identity: the same clip on another Mac, where the media sits
	/// under a different absolute path, hashes the same.
	///
	/// This is what Sonar hashes into a source's `contentHash`, and a shader's
	/// `#audio` lane stores a hash of that. So if this moved with the media, a
	/// project opened on a second Mac could never reconnect to its audio - not
	/// even after republishing the very same clips, because the key it looks up
	/// would have changed underneath it.
	///
	/// Filename, not full path: media moving folders is ordinary, and the edit
	/// suffix below carries enough (source range, curves, fades, filters) that
	/// two genuinely different clips still separate.
	static func identity(_ clip: FCPXMLParser.AudioClip) -> String {
		(clip.url?.lastPathComponent ?? clip.name) + edits(clip)
	}

	/// Everything about a clip that changes its processed audio, short of which
	/// file it came from. Shared so the two identities can't drift apart in what
	/// they consider an edit.
	private static func edits(_ clip: FCPXMLParser.AudioClip) -> String {
		"#\(clip.sourceStart)+\(clip.sourceDuration)"
			+ "/curve=\(volumeCurveHash(clip.volumeCurve))"
			+ "/fade=\(fadeHash(clip.fadeIn))-\(fadeHash(clip.fadeOut))"
			+ "/filters=\(filtersHash(clip.auFilters))"
			+ "/ch=\(channelsHash(clip.sourceChannels))"
			// Appended only when groups exist, so every clip without them keeps
			// the fingerprint it had before groups were introduced - a format
			// change here would orphan published-source links (`identity` is
			// what Sonar's contentHash builds on).
			+ (clip.sourceChannelGroups.map { "/chg=\(groupsHash($0))" } ?? "")
	}

	private static func groupsHash(_ groups: [FCPXMLParser.ChannelSourceGroup]) -> String {
		groups.map {
			"\($0.channels.map(String.init).joined(separator: ","))@\($0.gainDB)"
		}.joined(separator: "|")
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
			return
				"\(f.auType)/\(f.auSubtype)/\(f.auManufacturer)/\(f.effectState?.count ?? 0)/\(params)"
		}.joined(separator: "|") ?? "none"
	}
}
