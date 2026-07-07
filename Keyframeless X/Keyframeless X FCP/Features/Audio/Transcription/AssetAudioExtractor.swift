/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// Decodes an asset's audio track to a temp Float32 mono WAV, optionally
/// trimmed to a `timeRange` and picking specific 1-indexed `sourceChannels`
/// (channel-pick + per-frame average downmix).
enum AssetAudioExtractor {

	static func extract(
		from url: URL, sourceChannels: [Int]? = nil,
		timeRange: (start: Double, duration: Double)? = nil
	) async throws -> URL {
		let asset = AVURLAsset(url: url)
		guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
			throw NSError(domain: "AssetAudioExtractor", code: 10)
		}

		let (sampleRate, trackChannels) = try await MultichannelAudioReader.trackFormat(track)
		let pickedChannels = MultichannelAudioReader.resolveChannels(
			sourceChannels, trackChannels: trackChannels)
		guard !pickedChannels.isEmpty else {
			throw NSError(domain: "AssetAudioExtractor", code: 11)
		}

		let cmRange: CMTimeRange? = timeRange.map {
			let ts = CMTimeScale(sampleRate)
			return CMTimeRange(
				start: CMTime(seconds: $0.start, preferredTimescale: ts),
				duration: CMTime(seconds: max(0, $0.duration), preferredTimescale: ts))
		}
		let source = try MultichannelAudioReader.makeSource(
			asset: asset, track: track, sampleRate: sampleRate, channels: trackChannels,
			timeRange: cmRange)

		let wavURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("kk_extracted_\(UUID().uuidString).wav")
		guard
			let monoFormat = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
				interleaved: false)
		else { throw NSError(domain: "AssetAudioExtractor", code: 13) }
		let outFile = try AVAudioFile(
			forWriting: wavURL, settings: monoFormat.settings,
			commonFormat: .pcmFormatFloat32, interleaved: false)

		try MultichannelAudioReader.readSamples(source) { src, frames, _ in
			guard
				let monoBuffer = AVAudioPCMBuffer(
					pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames))
			else { return }
			monoBuffer.frameLength = AVAudioFrameCount(frames)
			MultichannelAudioReader.downmixToMono(
				src, dst: monoBuffer.floatChannelData![0],
				frames: frames, trackChannels: trackChannels,
				pickedChannels: pickedChannels)
			try outFile.write(from: monoBuffer)
		}

		return wavURL
	}

	private static let whisperSampleRate: Double = 16000

	/// Resamples + downmixes (if needed) to Whisper's 16kHz mono Float32.
	/// Returns the input buffer unchanged when it already matches.
	static func resampleToWhisperFormat(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
		guard
			let monoFormat = AVAudioFormat(
				commonFormat: .pcmFormatFloat32,
				sampleRate: whisperSampleRate,
				channels: 1,
				interleaved: false
			)
		else { throw NSError(domain: "AssetAudioExtractor", code: 1) }

		if buffer.format.sampleRate == whisperSampleRate && buffer.format.channelCount == 1 {
			return buffer
		}

		guard let converter = AVAudioConverter(from: buffer.format, to: monoFormat) else {
			throw NSError(domain: "AssetAudioExtractor", code: 2)
		}

		let ratio = whisperSampleRate / buffer.format.sampleRate
		let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
		guard
			let outputBuffer = AVAudioPCMBuffer(
				pcmFormat: monoFormat,
				frameCapacity: outputFrameCount
			)
		else { throw NSError(domain: "AssetAudioExtractor", code: 3) }

		var error: NSError?
		converter.convert(to: outputBuffer, error: &error) { _, outStatus in
			outStatus.pointee = .haveData
			return buffer
		}
		if let error { throw error }
		return outputBuffer
	}
}
