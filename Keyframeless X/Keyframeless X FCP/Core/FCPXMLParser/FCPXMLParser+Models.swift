/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension FCPXMLParser {

	struct DropItem: Codable {
		let name: String
		let kind: String
		let dialogueCount: Int
	}

	struct ProjectFormat: Codable {
		static let `default` = ProjectFormat(
			name: "FFVideoFormat1080p60",
			frameDuration: "100/6000s",
			width: 1920,
			height: 1080,
			sequenceDuration: 0,
			tcStart: nil
		)

		let name: String
		let frameDuration: String
		let width: Int
		let height: Int
		let sequenceDuration: Double
		/// The sequence's start timecode in seconds (02:00:00:00 -> 7200).
		///
		/// FCP's timeline clock STARTS here - a clip at project 6.05s in a project
		/// starting at 7200 is timeline second 7206.05, which is what
		/// `timelineTime:fromInputTime:` reports to a plugin. Clip positions are
		/// normalised against it (they count from 0), so anything published for a
		/// plugin has to add it back.
		///
		/// Optional: added after this was already persisted, and a non-optional
		/// field would fail to decode every stored project.
		let tcStart: Double?

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

	struct VolumePoint: Codable {
		let time: Double
		let dB: Double
	}

	struct FadeSpec: Codable {
		let duration: Double
		let type: String
	}

	struct AudioFilter: Codable {
		let auType: UInt32
		let auSubtype: UInt32
		let auManufacturer: UInt32
		let name: String
		let effectState: Data?
		let paramOverrides: [ParamOverride]

		struct ParamOverride: Codable {
			let key: UInt32
			let value: Float
			let keyframes: [Keyframe]?

			struct Keyframe: Codable {
				let time: Double
				let value: Float
			}
		}
	}

	/// Compound-level adjustments that live on the wrapping `ref-clip` /
	/// `mc-clip`. Sampled in *compound-local* seconds (0 = compound boundary's
	/// start in the main timeline). Combined multiplicatively with the inner
	/// clip's own `volumeCurve` / fades at apply time.
	struct OuterCompound: Codable {
		let volumeCurve: [VolumePoint]?
		let fadeIn: FadeSpec?
		let fadeOut: FadeSpec?
		/// Distance from the compound boundary's start to this inner clip's
		/// start, in seconds. Used at apply time to translate per-sample
		/// source time into compound-local time for outer-curve lookup.
		let offsetInCompound: Double
		let compoundDuration: Double

		var hasVolumeCurve: Bool { !(volumeCurve?.isEmpty ?? true) }
		var hasFade: Bool { fadeIn != nil || fadeOut != nil }
	}

	struct AudioClip: Codable {
		let name: String
		let start: Double
		let end: Double
		let sourceStart: Double
		let sourceDuration: Double
		let url: URL?
		let bookmark: Data?
		let isCompound: Bool
		let volumeCurve: [VolumePoint]?
		let fadeIn: FadeSpec?
		let fadeOut: FadeSpec?
		let auFilters: [AudioFilter]?
		let sourceChannels: [Int]?
		let unhandledAdjustments: [String]?
		let outer: OuterCompound?
		/// Base audio role ("dialogue" / "music" / "effects" / custom), shown as a
		/// label on the Sonar timeline. Optional so previously-persisted clips
		/// still decode.
		var role: String?

		struct ResolvedURL {
			let url: URL
			let isSecurityScoped: Bool
			func stopAccess() {
				if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
			}
		}

		func resolvedURL() throws -> ResolvedURL {
			if let bookmark {
				var isStale = false
				if let scopedURL = try? URL(
					resolvingBookmarkData: bookmark,
					options: .withSecurityScope,
					relativeTo: nil,
					bookmarkDataIsStale: &isStale
				) {
					let accessing = scopedURL.startAccessingSecurityScopedResource()
					return ResolvedURL(url: scopedURL, isSecurityScoped: accessing)
				}
			}
			guard let url else { throw CocoaError(.fileNoSuchFile) }
			return ResolvedURL(url: url, isSecurityScoped: false)
		}

		func data() throws -> Data {
			let resolved = try resolvedURL()
			defer { resolved.stopAccess() }
			return try Data(contentsOf: resolved.url)
		}
	}

	struct AudioEffectResource {
		let auType: UInt32
		let auSubtype: UInt32
		let auManufacturer: UInt32
		let name: String
	}

	struct AssetResource {
		let url: URL
		let bookmark: Data?
		let mediaStart: Double
		/// Whether the underlying media carries any audio at all. A video-only
		/// asset declares neither `hasAudio` nor `audioSources`.
		let hasAudio: Bool
	}

	/// Carries the mapping context when walking inside a compound clip's
	/// media spine.
	/// - mainOffset: where the ref-clip starts in the main timeline.
	/// - internalStart/End: the trimmed window in the compound clip's time
	///   space (tcStart-relative).
	/// - tcStart: the compound sequence's tcStart, used to normalise clip
	///   offsets.
	struct CompoundContext {
		let mainOffset: Double
		let internalStart: Double
		let internalEnd: Double
		let tcStart: Double
		/// `<adjust-volume>` on the outer ref-clip / mc-clip, in compound-local
		/// seconds. May be a single constant-offset point (static `amount=`),
		/// or a multi-point keyframed curve.
		let outerVolumeCurve: [VolumePoint]?
		/// `<filter-audio>` chain on the outer ref-clip / mc-clip, applied
		/// after every inner clip's own filter chain.
		let outerAuFilters: [AudioFilter]?
		let outerFadeIn: FadeSpec?
		let outerFadeOut: FadeSpec?

		/// Duration of the visible compound window in seconds. Needed at apply
		/// time so the outer fadeOut anchors at the compound's end rather than
		/// the inner clip's end.
		var compoundDuration: Double { internalEnd - internalStart }

		/// Builds an `OuterCompound` for an emitted `AudioClip` that lives
		/// inside this compound, or returns nil when the wrapper has no
		/// volume/fade adjustments worth propagating.
		func outerCompound(mainStart: Double) -> OuterCompound? {
			let hasVolume = !(outerVolumeCurve?.isEmpty ?? true)
			let hasFade = outerFadeIn != nil || outerFadeOut != nil
			guard hasVolume || hasFade else { return nil }
			return OuterCompound(
				volumeCurve: outerVolumeCurve,
				fadeIn: outerFadeIn, fadeOut: outerFadeOut,
				offsetInCompound: mainStart - mainOffset,
				compoundDuration: compoundDuration)
		}

		init(
			mainOffset: Double, internalStart: Double, internalEnd: Double,
			tcStart: Double,
			outerVolumeCurve: [VolumePoint]? = nil, outerAuFilters: [AudioFilter]? = nil,
			outerFadeIn: FadeSpec? = nil, outerFadeOut: FadeSpec? = nil
		) {
			self.mainOffset = mainOffset
			self.internalStart = internalStart
			self.internalEnd = internalEnd
			self.tcStart = tcStart
			self.outerVolumeCurve = outerVolumeCurve
			self.outerAuFilters = outerAuFilters
			self.outerFadeIn = outerFadeIn
			self.outerFadeOut = outerFadeOut
		}
	}
}
