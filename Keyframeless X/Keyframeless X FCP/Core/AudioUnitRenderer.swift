/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import AudioToolbox
import Foundation

enum AudioUnitRenderer {

	static func process(
		buffer input: AVAudioPCMBuffer,
		filters: [FCPXMLParser.AudioFilter],
		baseSourceTime: Double = 0
	) async throws -> AVAudioPCMBuffer {
		guard !filters.isEmpty else { return input }

		let engine = AVAudioEngine()
		let player = AVAudioPlayerNode()
		engine.attach(player)

		var auNodes: [AVAudioUnit] = []
		for f in filters {
			let au = try await instantiate(filter: f)
			engine.attach(au)
			auNodes.append(au)
		}

		var previous: AVAudioNode = player
		for au in auNodes {
			engine.connect(previous, to: au, format: input.format)
			previous = au
		}
		engine.connect(previous, to: engine.mainMixerNode, format: input.format)

		let maxFrames: AVAudioFrameCount = 4096
		try engine.enableManualRenderingMode(
			.offline, format: input.format, maximumFrameCount: maxFrames)
		try engine.start()
		player.play()
		player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)

		guard
			let output = AVAudioPCMBuffer(
				pcmFormat: engine.manualRenderingFormat, frameCapacity: input.frameLength)
		else {
			throw NSError(domain: "AudioUnitRenderer", code: 1)
		}

		var written: AVAudioFrameCount = 0
		let total = input.frameLength
		let sampleRate = input.format.sampleRate
		while written < total {
			let want = min(maxFrames, total - written)
			guard
				let chunk = AVAudioPCMBuffer(
					pcmFormat: engine.manualRenderingFormat, frameCapacity: want)
			else { break }
			let chunkTime = baseSourceTime + Double(written) / sampleRate
			for (au, filter) in zip(auNodes, filters) {
				for override in filter.paramOverrides {
					guard let kfs = override.keyframes, kfs.count > 1 else { continue }
					let v = Keyframes.interpolateParam(kfs, at: chunkTime)
					AudioUnitSetParameter(
						au.audioUnit, AudioUnitParameterID(override.key),
						kAudioUnitScope_Global, 0, AudioUnitParameterValue(v), 0)
				}
			}
			let status = try engine.renderOffline(want, to: chunk)
			switch status {
			case .success:
				if chunk.frameLength == 0 { break }
				try appendBuffer(chunk, to: output, written: &written)
			case .insufficientDataFromInputNode, .cannotDoInCurrentContext, .error:
				break
			@unknown default:
				break
			}
			if chunk.frameLength == 0 { break }
		}

		player.stop()
		engine.stop()
		return output
	}

	private static func appendBuffer(
		_ src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer, written: inout AVAudioFrameCount
	) throws {
		guard let srcData = src.floatChannelData, let dstData = dst.floatChannelData else {
			throw NSError(domain: "AudioUnitRenderer", code: 2)
		}
		let channels = Int(src.format.channelCount)
		let frames = Int(src.frameLength)
		for ch in 0..<channels {
			let srcPtr = srcData[ch]
			let dstPtr = dstData[ch].advanced(by: Int(written))
			dstPtr.update(from: srcPtr, count: frames)
		}
		written += src.frameLength
		dst.frameLength = written
	}

	static func instantiate(filter f: FCPXMLParser.AudioFilter) async throws -> AVAudioUnit {
		let desc = AudioComponentDescription(
			componentType: f.auType,
			componentSubType: f.auSubtype,
			componentManufacturer: f.auManufacturer,
			componentFlags: 0,
			componentFlagsMask: 0
		)
		let au = try await withCheckedThrowingContinuation {
			(cont: CheckedContinuation<AVAudioUnit, Error>) in
			AVAudioUnit.instantiate(with: desc, options: []) { unit, error in
				if let error {
					cont.resume(throwing: error)
				} else if let unit {
					cont.resume(returning: unit)
				} else {
					cont.resume(
						throwing: NSError(domain: "AudioUnitRenderer", code: 3))
				}
			}
		}

		if let state = f.effectState,
			let plist = try? PropertyListSerialization.propertyList(
				from: state, options: [], format: nil) as? [String: Any]
		{
			var classInfo: CFPropertyList = plist as CFPropertyList
			let status = AudioUnitSetProperty(
				au.audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0,
				&classInfo, UInt32(MemoryLayout<CFPropertyList>.size))
			if status != noErr {
				print("[AudioUnitRenderer] ClassInfo set failed (\(status)) for \(f.name)")
			}
		}

		for override in f.paramOverrides {
			let status = AudioUnitSetParameter(
				au.audioUnit, AudioUnitParameterID(override.key), kAudioUnitScope_Global, 0,
				AudioUnitParameterValue(override.value), 0)
			if status != noErr {
				print(
					"[AudioUnitRenderer] param \(override.key)=\(override.value) set failed (\(status)) for \(f.name)"
				)
			}
		}
		return au
	}
}
