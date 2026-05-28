/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// In-place PCM gain helpers used by both the offline
/// `ProcessedAudioRenderer` (via `applyVolumeCurves`) and the live
/// `LivePlaybackSession` (via `sampleGain` / `fadeMultiplier`).
enum AudioBufferProcessing {

	/// Applies each clip mapping's volume curve and fade envelope, in place,
	/// over the clip's frame range within the buffer.
	static func applyVolumeCurves(
		buffer: AVAudioPCMBuffer,
		segmentStart: Double,
		sampleRate: Double,
		mappings: [AudioPreparer.ClipMapping]
	) {
		guard let channelData = buffer.floatChannelData else { return }
		let channels = Int(buffer.format.channelCount)
		let frames = Int(buffer.frameLength)

		for mapping in mappings {
			let hasCurve = !(mapping.volumeCurve?.isEmpty ?? true)
			let hasFade = mapping.fadeIn != nil || mapping.fadeOut != nil
			let hasOuterCurve = mapping.outer?.hasVolumeCurve == true
			let hasOuterFade = mapping.outer?.hasFade == true
			guard hasCurve || hasOuterCurve || hasFade || hasOuterFade else { continue }
			let (startFrame, endFrame) = mappingFrameRange(
				mapping: mapping, segmentStart: segmentStart, sampleRate: sampleRate,
				totalFrames: frames)
			guard endFrame > startFrame else { continue }

			if let dB = constantFoldDB(
				mapping: mapping, hasFade: hasFade, hasOuterFade: hasOuterFade)
			{
				applyConstantGain(
					channelData: channelData, channels: channels,
					startFrame: startFrame, endFrame: endFrame, dB: dB)
				continue
			}

			applyPerSampleGain(
				channelData: channelData, channels: channels,
				startFrame: startFrame, endFrame: endFrame,
				segmentStart: segmentStart, sampleRate: sampleRate,
				mapping: mapping)
		}
	}

	/// Per-sample gain at a given source time. Returns the combined inner
	/// and outer-compound volume * fade multiplier. Shared by offline and
	/// live playback so the math doesn't drift between paths.
	static func sampleGain(
		sourceTime t: Double,
		clipSourceStart: Double, clipSourceDuration: Double,
		volumeCurve: [FCPXMLParser.VolumePoint]?,
		fadeIn: FCPXMLParser.FadeSpec?, fadeOut: FCPXMLParser.FadeSpec?,
		outer: FCPXMLParser.OuterCompound?
	) -> Float {
		let clipLocal = t - clipSourceStart
		var gain: Float = 1
		if let curve = volumeCurve, !curve.isEmpty {
			gain *= dBToLinear(Keyframes.interpolateDB(curve, at: t))
		}
		if fadeIn != nil || fadeOut != nil {
			gain *= fadeMultiplier(
				clipLocal: clipLocal, duration: clipSourceDuration,
				fadeIn: fadeIn, fadeOut: fadeOut)
		}
		if let outer {
			let compoundLocal = clipLocal + outer.offsetInCompound
			if let oc = outer.volumeCurve, !oc.isEmpty {
				gain *= dBToLinear(Keyframes.interpolateDB(oc, at: compoundLocal))
			}
			if outer.hasFade {
				gain *= fadeMultiplier(
					clipLocal: compoundLocal, duration: outer.compoundDuration,
					fadeIn: outer.fadeIn, fadeOut: outer.fadeOut)
			}
		}
		return gain
	}

	/// Combined fadeIn + fadeOut amplitude multiplier at clip-local time `tc`.
	static func fadeMultiplier(
		clipLocal tc: Double, duration: Double,
		fadeIn: FCPXMLParser.FadeSpec?, fadeOut: FCPXMLParser.FadeSpec?
	) -> Float {
		var m: Float = 1
		if let fi = fadeIn, fi.duration > 0, tc < fi.duration {
			let f = max(0, min(1, tc / fi.duration))
			m *= ease(Float(f), type: fi.type)
		}
		if let fo = fadeOut, fo.duration > 0 {
			let fadeOutStart = duration - fo.duration
			if tc > fadeOutStart {
				let f = max(0, min(1, (duration - tc) / fo.duration))
				m *= ease(Float(f), type: fo.type)
			}
		}
		return m
	}

	private static func mappingFrameRange(
		mapping: AudioPreparer.ClipMapping, segmentStart: Double, sampleRate: Double,
		totalFrames: Int
	) -> (Int, Int) {
		let start = max(
			0, Int(((mapping.clipSourceStart - segmentStart) * sampleRate).rounded()))
		let end = min(
			totalFrames,
			Int(
				((mapping.clipSourceStart + mapping.clipSourceDuration - segmentStart)
					* sampleRate).rounded()))
		return (start, end)
	}

	/// When neither inner nor outer has a fade, and both volume curves (if
	/// present) are single-point statics, the whole mapping reduces to a
	/// constant dB offset. Returns the folded dB, or nil if a per-sample
	/// pass is required.
	private static func constantFoldDB(
		mapping: AudioPreparer.ClipMapping, hasFade: Bool, hasOuterFade: Bool
	) -> Double? {
		guard !hasFade && !hasOuterFade else { return nil }
		let inner = mapping.volumeCurve
		let outerCurve = mapping.outer?.volumeCurve
		guard (inner?.count ?? 0) == 1, (outerCurve?.count ?? 0) <= 1 else { return nil }
		return (inner?[0].dB ?? 0) + (outerCurve?.first?.dB ?? 0)
	}

	private static func applyConstantGain(
		channelData: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int,
		startFrame: Int, endFrame: Int, dB: Double
	) {
		let gain = dBToLinear(dB)
		if abs(gain - 1) < 1e-6 { return }
		for ch in 0..<channels {
			let p = channelData[ch]
			for i in startFrame..<endFrame { p[i] *= gain }
		}
	}

	private static func applyPerSampleGain(
		channelData: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int,
		startFrame: Int, endFrame: Int,
		segmentStart: Double, sampleRate: Double,
		mapping: AudioPreparer.ClipMapping
	) {
		for i in startFrame..<endFrame {
			let t = segmentStart + Double(i) / sampleRate
			let gain = sampleGain(
				sourceTime: t,
				clipSourceStart: mapping.clipSourceStart,
				clipSourceDuration: mapping.clipSourceDuration,
				volumeCurve: mapping.volumeCurve,
				fadeIn: mapping.fadeIn, fadeOut: mapping.fadeOut,
				outer: mapping.outer)
			for ch in 0..<channels { channelData[ch][i] *= gain }
		}
	}

	private static func dBToLinear(_ dB: Double) -> Float {
		Float(pow(10.0, dB / 20.0))
	}

	private static func ease(_ f: Float, type: String) -> Float {
		switch type {
		case "easeIn": return f * f
		case "easeOut": return 1 - (1 - f) * (1 - f)
		case "easeInOut": return f * f * (3 - 2 * f)
		default: return f
		}
	}
}
