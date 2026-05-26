/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// Builds an `AVAssetReader` configured to deliver multichannel interleaved
/// Float32 PCM with a discrete-in-order channel layout (so the channels in
/// each sample frame are in source order, never reordered to a canonical
/// surround layout). Also provides the channel-pick → mono downmix that both
/// `AudioPreparer.extractAudioTrack` and `LivePlaybackSession` need.
enum MultichannelAudioReader {

	struct Source {
		let reader: AVAssetReader
		let output: AVAssetReaderTrackOutput
		let sampleRate: Double
		let trackChannels: Int
	}

	struct Picked {
		let source: Source
		/// 0-indexed channels in the source frame to sum into mono.
		let channels: [Int]
	}

	/// Resolves the audio track's sample rate and channel count from its
	/// `formatDescriptions`. Defaults to 48000Hz / 1ch if unavailable.
	static func trackFormat(_ track: AVAssetTrack) async throws -> (
		sampleRate: Double, channels: Int
	) {
		let descs = try await track.load(.formatDescriptions)
		let asbd = descs.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
		return (asbd?.pointee.mSampleRate ?? 48000, Int(asbd?.pointee.mChannelsPerFrame ?? 1))
	}

	/// Resolves 1-indexed source channels (as written in FCPXML) to 0-indexed
	/// channels valid for the track. `nil` defaults to `[0]` (channel 1).
	static func resolveChannels(_ sourceChannels: [Int]?, trackChannels: Int) -> [Int] {
		if let sc = sourceChannels {
			return sc.compactMap { ch in
				let idx = ch - 1
				return (idx >= 0 && idx < trackChannels) ? idx : nil
			}
		}
		return [0]
	}

	static func makeSource(
		asset: AVURLAsset, track: AVAssetTrack,
		sampleRate: Double, channels: Int,
		timeRange: CMTimeRange? = nil
	) throws -> Source {
		var discreteLayout = AudioChannelLayout()
		discreteLayout.mChannelLayoutTag =
			kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
		let layoutData = Data(
			bytes: &discreteLayout, count: MemoryLayout<AudioChannelLayout>.size)

		let reader = try AVAssetReader(asset: asset)
		if let range = timeRange { reader.timeRange = range }
		let output = AVAssetReaderTrackOutput(
			track: track,
			outputSettings: [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVLinearPCMBitDepthKey: 32,
				AVLinearPCMIsFloatKey: true,
				AVLinearPCMIsBigEndianKey: false,
				AVLinearPCMIsNonInterleaved: false,
				AVNumberOfChannelsKey: channels,
				AVSampleRateKey: sampleRate,
				AVChannelLayoutKey: layoutData,
			])
		reader.add(output)
		return Source(
			reader: reader, output: output, sampleRate: sampleRate, trackChannels: channels)
	}

	/// Iterates sample buffers from the reader. Each callback receives the
	/// chunk's interleaved Float32 pointer, the number of audio frames it
	/// contains, and the chunk's start time in *output samples produced so
	/// far* (i.e. cumulative frame count).
	static func readSamples(
		_ source: Source,
		body: (UnsafePointer<Float>, _ frames: Int, _ cumulativeFrames: Int) throws -> Void
	) throws {
		source.reader.startReading()
		var cumulative = 0
		while source.reader.status == .reading {
			guard let sb = source.output.copyNextSampleBuffer() else { break }
			guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
			var length = 0
			var dataPtr: UnsafeMutablePointer<Int8>?
			CMBlockBufferGetDataPointer(
				block, atOffset: 0, lengthAtOffsetOut: nil,
				totalLengthOut: &length, dataPointerOut: &dataPtr)
			guard let ptr = dataPtr else { continue }
			let totalFloats = length / MemoryLayout<Float>.size
			let frames = totalFloats / source.trackChannels
			guard frames > 0 else { continue }
			try ptr.withMemoryRebound(to: Float.self, capacity: totalFloats) { typed in
				try body(typed, frames, cumulative)
			}
			cumulative += frames
		}
	}

	/// Downmix selected interleaved-channel samples to mono. Output is the
	/// per-channel average of `pickedChannels` at each frame.
	static func downmixToMono(
		_ src: UnsafePointer<Float>,
		dst: UnsafeMutablePointer<Float>,
		frames: Int, trackChannels: Int, pickedChannels: [Int]
	) {
		let scale: Float = pickedChannels.count > 0 ? 1.0 / Float(pickedChannels.count) : 1
		for i in 0..<frames {
			var sum: Float = 0
			let base = i * trackChannels
			for ch in pickedChannels { sum += src[base + ch] }
			dst[i] = sum * scale
		}
	}
}
