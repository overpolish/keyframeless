/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import AudioToolbox
import Foundation

/// One-shot offline render wrapper around `AudioUnitChain`. Builds a chain
/// for the clip's filters, pushes the whole input buffer through it in
/// `maxFramesPerSlice`-sized chunks, then disposes the chain.
///
/// For streaming (live playback) use `AudioUnitChain` directly so the chain
/// outlives a single buffer and AU internal state (delay lines, reverb
/// tails) carries over between pump cycles.
enum AudioUnitRenderer {

	static func process(
		buffer input: AVAudioPCMBuffer,
		filters: [FCPXMLParser.AudioFilter],
		baseSourceTime: Double = 0
	) async throws -> AVAudioPCMBuffer {
		guard !filters.isEmpty else { return input }
		guard let inputPtr = input.floatChannelData?[0],
			let output = AVAudioPCMBuffer(
				pcmFormat: input.format, frameCapacity: input.frameLength)
		else { throw NSError(domain: "AudioUnitRenderer", code: 1) }

		let chain = try AudioUnitChain(filters: filters, format: input.format)
		guard !chain.isEmpty else { return input }

		let total = Int(input.frameLength)
		let maxF = Int(chain.maxFramesPerSlice)
		let outputPtr = output.floatChannelData![0]
		var produced = 0
		while produced < total {
			if Task.isCancelled { throw CancellationError() }
			let want = min(maxF, total - produced)
			chain.updateKeyframes(
				at: baseSourceTime + Double(produced) / input.format.sampleRate)
			let status = chain.renderChunk(
				input: inputPtr.advanced(by: produced),
				output: outputPtr.advanced(by: produced),
				frames: want)
			if status != noErr {
				print("[AudioUnitRenderer] render failed at frame \(produced): \(status)")
				break
			}
			produced += want
		}
		output.frameLength = AVAudioFrameCount(produced)
		return output
	}
}
