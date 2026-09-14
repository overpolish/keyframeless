/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Accelerate
import Foundation

/// Decodes an asset's audio to a temp Float32 mono WAV, optionally trimmed to
/// a `timeRange` and downmixing specific 1-indexed channel `weights` (from the
/// clip's channel-source groups). Weights use FCPXML's flat numbering across
/// all audio tracks, so picks can span tracks (screen recording system audio
/// + mic).
enum AssetAudioExtractor {

	static func extract(
		from url: URL, weights: [FCPXMLParser.ChannelWeight]? = nil,
		timeRange: (start: Double, duration: Double)? = nil
	) async throws -> URL {
		let asset = AVURLAsset(url: url)
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		guard !tracks.isEmpty else {
			throw NSError(domain: "AssetAudioExtractor", code: 10)
		}

		var formats: [(sampleRate: Double, channels: Int)] = []
		for track in tracks {
			formats.append(try await MultichannelAudioReader.trackFormat(track))
		}
		let perTrackPicks = MultichannelAudioReader.resolveFlatWeights(
			weights, trackChannelCounts: formats.map(\.channels))
		let involved = perTrackPicks.enumerated().filter { !$0.element.isEmpty }
		guard !involved.isEmpty else {
			throw NSError(domain: "AssetAudioExtractor", code: 11)
		}

		// Every part is decoded at one shared rate so the per-frame sum in
		// `mixMonoFiles` lines up even when tracks disagree on sample rate.
		let outRate = formats[involved[0].offset].sampleRate
		var parts: [URL] = []
		do {
			for (i, picked) in involved {
				parts.append(
					try extractTrackMono(
						asset: asset, track: tracks[i], trackChannels: formats[i].channels,
						outRate: outRate, picked: picked, timeRange: timeRange))
			}
		} catch {
			for p in parts { try? FileManager.default.removeItem(at: p) }
			throw error
		}
		if parts.count == 1 { return parts[0] }
		defer { for p in parts { try? FileManager.default.removeItem(at: p) } }
		return try mixMonoFiles(parts, sampleRate: outRate)
	}

	/// Streams one track's weighted channel picks to a temp mono WAV; the
	/// weights already carry each channel's share, so parts just sum.
	private static func extractTrackMono(
		asset: AVURLAsset, track: AVAssetTrack, trackChannels: Int,
		outRate: Double, picked: [MultichannelAudioReader.TrackPick],
		timeRange: (start: Double, duration: Double)?
	) throws -> URL {
		let cmRange: CMTimeRange? = timeRange.map {
			let ts = CMTimeScale(outRate)
			return CMTimeRange(
				start: CMTime(seconds: $0.start, preferredTimescale: ts),
				duration: CMTime(seconds: max(0, $0.duration), preferredTimescale: ts))
		}
		let source = try MultichannelAudioReader.makeSource(
			asset: asset, track: track, sampleRate: outRate, channels: trackChannels,
			timeRange: cmRange)

		let wavURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("kk_extracted_\(UUID().uuidString).wav")
		guard
			let monoFormat = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: 1,
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
				frames: frames, trackChannels: trackChannels, picks: picked)
			try outFile.write(from: monoBuffer)
		}

		return wavURL
	}

	/// Sums several mono WAVs frame-by-frame into one, streamed in chunks.
	/// Parts may differ in length by a few frames (per-track AAC priming);
	/// a part past its end just stops contributing.
	private static func mixMonoFiles(_ urls: [URL], sampleRate: Double) throws -> URL {
		guard
			let monoFormat = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
				interleaved: false)
		else { throw NSError(domain: "AssetAudioExtractor", code: 13) }
		let files = try urls.map {
			try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false)
		}
		let outURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("kk_extracted_\(UUID().uuidString).wav")
		let outFile = try AVAudioFile(
			forWriting: outURL, settings: monoFormat.settings,
			commonFormat: .pcmFormatFloat32, interleaved: false)

		let chunk: AVAudioFrameCount = 65536
		guard
			let acc = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk),
			let tmp = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk)
		else { throw NSError(domain: "AssetAudioExtractor", code: 13) }

		let totalFrames = files.map(\.length).max() ?? 0
		var written: AVAudioFramePosition = 0
		while written < totalFrames {
			let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), totalFrames - written))
			acc.frameLength = n
			vDSP_vclr(acc.floatChannelData![0], 1, vDSP_Length(n))
			for file in files {
				guard file.framePosition < file.length else { continue }
				try file.read(into: tmp, frameCount: n)
				let got = Int(tmp.frameLength)
				guard got > 0 else { continue }
				vDSP_vadd(
					acc.floatChannelData![0], 1, tmp.floatChannelData![0], 1,
					acc.floatChannelData![0], 1, vDSP_Length(got))
			}
			try outFile.write(from: acc)
			written += AVAudioFramePosition(n)
		}
		return outURL
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
