/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// In-place PCM gain helpers used by both the offline
/// `ProcessedAudioRenderer` (via `AudioPreparer.applyVolumeCurves`) and the
/// live `LivePlaybackSession` (via `fadeMultiplier`).
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
			let curve = mapping.volumeCurve
			let hasCurve = !(curve?.isEmpty ?? true)
			let hasFade = mapping.fadeIn != nil || mapping.fadeOut != nil
			guard hasCurve || hasFade else { continue }
			let (startFrame, endFrame) = mappingFrameRange(
				mapping: mapping, segmentStart: segmentStart, sampleRate: sampleRate,
				totalFrames: frames)
			guard endFrame > startFrame else { continue }

			if !hasFade, let curve, curve.count == 1 {
				applyConstantGain(
					channelData: channelData, channels: channels,
					startFrame: startFrame, endFrame: endFrame, dB: curve[0].dB)
				continue
			}

			applyPerSampleGain(
				channelData: channelData, channels: channels,
				startFrame: startFrame, endFrame: endFrame,
				segmentStart: segmentStart, sampleRate: sampleRate,
				curve: curve, mapping: mapping, hasFade: hasFade)
		}
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

	private static func applyConstantGain(
		channelData: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int,
		startFrame: Int, endFrame: Int, dB: Double
	) {
		let gain = Float(pow(10.0, dB / 20.0))
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
		curve: [FCPXMLParser.VolumePoint]?, mapping: AudioPreparer.ClipMapping,
		hasFade: Bool
	) {
		for i in startFrame..<endFrame {
			let t = segmentStart + Double(i) / sampleRate
			var gain: Float = 1
			if let curve, !curve.isEmpty {
				gain *= Float(pow(10.0, Keyframes.interpolateDB(curve, at: t) / 20.0))
			}
			if hasFade {
				gain *= fadeMultiplier(
					clipLocal: t - mapping.clipSourceStart,
					duration: mapping.clipSourceDuration,
					fadeIn: mapping.fadeIn, fadeOut: mapping.fadeOut)
			}
			for ch in 0..<channels { channelData[ch][i] *= gain }
		}
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

	private static func ease(_ f: Float, type: String) -> Float {
		switch type {
		case "easeIn": return f * f
		case "easeOut": return 1 - (1 - f) * (1 - f)
		case "easeInOut": return f * f * (3 - 2 * f)
		default: return f
		}
	}
}
