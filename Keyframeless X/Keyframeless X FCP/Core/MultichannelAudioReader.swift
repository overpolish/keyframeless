/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Accelerate
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

	/// Resolves the audio track's sample rate and channel count from its
	/// `formatDescriptions`. Defaults to 48000Hz / 1ch if unavailable.
	static func trackFormat(_ track: AVAssetTrack) async throws -> (
		sampleRate: Double, channels: Int
	) {
		let descs = try await track.load(.formatDescriptions)
		let asbd = descs.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
		return (asbd?.pointee.mSampleRate ?? 48000, Int(asbd?.pointee.mChannelsPerFrame ?? 1))
	}

	/// One channel of one track to fold into the mono downmix: 0-indexed
	/// within its track, with the linear weight it contributes at.
	struct TrackPick {
		let channel: Int
		let weight: Float
	}

	/// Resolves flat 1-indexed channel weights (FCPXML `srcCh` numbering is
	/// flat across the file's audio tracks: track 1 owns channels 1...N1,
	/// track 2 owns N1+1...N1+N2, and so on - a screen recording carries
	/// system audio as track 1 and the mic as track 2). Returns one pick list
	/// per track. `nil` defaults to channel 1 of the first track at unity.
	static func resolveFlatWeights(
		_ weights: [FCPXMLParser.ChannelWeight]?, trackChannelCounts: [Int]
	) -> [[TrackPick]] {
		var picks = [[TrackPick]](repeating: [], count: trackChannelCounts.count)
		if let weights {
			var base = 0
			for (i, count) in trackChannelCounts.enumerated() {
				for w in weights {
					let idx = w.channel - 1 - base
					if idx >= 0 && idx < count {
						picks[i].append(TrackPick(channel: idx, weight: w.weight))
					}
				}
				base += count
			}
		} else if !picks.isEmpty {
			picks[0] = [TrackPick(channel: 0, weight: 1)]
		}
		return picks
	}

	static func makeSource(
		asset: AVURLAsset, track: AVAssetTrack,
		sampleRate: Double, channels: Int,
		timeRange: CMTimeRange? = nil
	) throws -> Source {
		let reader = try AVAssetReader(asset: asset)
		if let range = timeRange { reader.timeRange = range }
		let output = makeTrackOutput(track: track, sampleRate: sampleRate, channels: channels)
		reader.add(output)
		return Source(
			reader: reader, output: output, sampleRate: sampleRate, trackChannels: channels)
	}

	static func makeTrackOutput(
		track: AVAssetTrack, sampleRate: Double, channels: Int
	) -> AVAssetReaderTrackOutput {
		var discreteLayout = AudioChannelLayout()
		discreteLayout.mChannelLayoutTag =
			kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
		let layoutData = Data(
			bytes: &discreteLayout, count: MemoryLayout<AudioChannelLayout>.size)
		return AVAssetReaderTrackOutput(
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
			if Task.isCancelled {
				source.reader.cancelReading()
				throw CancellationError()
			}
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

	/// Pull-based mono producer over one or more of a file's audio tracks.
	/// Each pull returns the weighted-downmix chunk summed across every
	/// involved track, kept frame-aligned by per-track pending buffers
	/// (decoders don't chunk identically). Built for `LivePlaybackSession`,
	/// whose picks can span tracks under FCPXML's flat `srcCh` numbering.
	final class MonoPickSource {
		private let reader: AVAssetReader
		private var taps: [Tap]
		let sampleRate: Double

		private struct Tap {
			let output: AVAssetReaderTrackOutput
			let channels: Int
			let picked: [TrackPick]
			var pending: [Float] = []
			var finished = false
		}

		private static let targetFrames = 4096

		/// `picks` is one pick list per track (`resolveFlatWeights` output);
		/// tracks with an empty list are not read at all.
		init(
			asset: AVURLAsset, tracks: [AVAssetTrack], trackChannelCounts: [Int],
			picks: [[TrackPick]], sampleRate: Double, timeRange: CMTimeRange? = nil
		) throws {
			let reader = try AVAssetReader(asset: asset)
			if let timeRange { reader.timeRange = timeRange }
			var taps: [Tap] = []
			for (i, track) in tracks.enumerated() where !picks[i].isEmpty {
				let output = MultichannelAudioReader.makeTrackOutput(
					track: track, sampleRate: sampleRate, channels: trackChannelCounts[i])
				reader.add(output)
				taps.append(
					Tap(output: output, channels: trackChannelCounts[i], picked: picks[i]))
			}
			guard !taps.isEmpty else {
				throw NSError(domain: "MonoPickSource", code: 1)
			}
			self.reader = reader
			self.taps = taps
			self.sampleRate = sampleRate
		}

		func startReading() { reader.startReading() }
		func cancelReading() { reader.cancelReading() }

		/// The next mono chunk, or nil when every track is exhausted. A track
		/// that ends earlier (AAC priming trims differ) contributes silence
		/// for the remainder rather than truncating the longer ones.
		func nextMonoChunk() -> [Float]? {
			for i in taps.indices {
				while !taps[i].finished, taps[i].pending.count < Self.targetFrames {
					if !appendNextBuffer(into: &taps[i]) { taps[i].finished = true }
				}
			}
			let emit = min(
				Self.targetFrames, taps.map { $0.pending.count }.max() ?? 0)
			guard emit > 0 else { return nil }
			var out = [Float](repeating: 0, count: emit)
			for i in taps.indices {
				let n = min(emit, taps[i].pending.count)
				guard n > 0 else { continue }
				taps[i].pending.withUnsafeBufferPointer { src in
					out.withUnsafeMutableBufferPointer { dst in
						vDSP_vadd(
							dst.baseAddress!, 1, src.baseAddress!, 1,
							dst.baseAddress!, 1, vDSP_Length(n))
					}
				}
				taps[i].pending.removeFirst(n)
			}
			return out
		}

		/// Pulls one sample buffer from the tap's output, downmixes it to
		/// weighted mono, and appends it to the tap's pending samples.
		/// Returns false when the output is exhausted.
		private func appendNextBuffer(into tap: inout Tap) -> Bool {
			guard let sb = tap.output.copyNextSampleBuffer(),
				let block = CMSampleBufferGetDataBuffer(sb)
			else { return false }
			var length = 0
			var dataPtr: UnsafeMutablePointer<Int8>?
			CMBlockBufferGetDataPointer(
				block, atOffset: 0, lengthAtOffsetOut: nil,
				totalLengthOut: &length, dataPointerOut: &dataPtr)
			guard let ptr = dataPtr else { return true }
			let totalFloats = length / MemoryLayout<Float>.size
			let frames = totalFloats / tap.channels
			guard frames > 0 else { return true }
			let base = tap.pending.count
			tap.pending.append(contentsOf: repeatElement(0, count: frames))
			let channels = tap.channels
			let picked = tap.picked
			ptr.withMemoryRebound(to: Float.self, capacity: totalFloats) { src in
				tap.pending.withUnsafeMutableBufferPointer { dst in
					MultichannelAudioReader.downmixToMono(
						src, dst: dst.baseAddress! + base,
						frames: frames, trackChannels: channels, picks: picked)
				}
			}
			return true
		}
	}

	/// Downmix selected interleaved-channel samples to mono: each frame is the
	/// weighted sum of the picked channels. Weights come from the clip's
	/// channel-source groups, so a caller never rescales the result.
	static func downmixToMono(
		_ src: UnsafePointer<Float>,
		dst: UnsafeMutablePointer<Float>,
		frames: Int, trackChannels: Int, picks: [TrackPick]
	) {
		for i in 0..<frames {
			var sum: Float = 0
			let base = i * trackChannels
			for pick in picks { sum += src[base + pick.channel] * pick.weight }
			dst[i] = sum
		}
	}
}
