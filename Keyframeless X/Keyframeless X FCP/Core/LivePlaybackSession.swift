/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// Owns the live `AVAudioEngine` + `AVAssetReader` producer for one clip
/// start. Lives off the main actor. Stop is idempotent.
///
/// Engine wiring: producer → `AVAudioPlayerNode` → [AU chain] → mainMixer.
/// The producer reads multichannel Float32 PCM from the source asset, picks
/// and downmixes the active channels to mono, applies volume curve + fades
/// per-sample, and schedules buffers onto the player node with backpressure
/// (at most `prerollCount` chunks in flight at a time).
final class LivePlaybackSession: @unchecked Sendable {
	private let engine = AVAudioEngine()
	private let playerNode = AVAudioPlayerNode()
	private let auNodes: [AVAudioUnit]
	private let auFilters: [FCPXMLParser.AudioFilter]
	private let reader: AVAssetReader
	private let readerOutput: AVAssetReaderTrackOutput
	private let monoFormat: AVAudioFormat
	private let trackChannels: Int
	private let trackSampleRate: Double
	private let pickedChannels: [Int]
	private let volumeCurve: [FCPXMLParser.VolumePoint]?
	private let fadeIn: FCPXMLParser.FadeSpec?
	private let fadeOut: FCPXMLParser.FadeSpec?
	private let clipSourceStart: Double
	private let clipSourceDuration: Double
	private let resolvedURL: FCPXMLParser.AudioClip.ResolvedURL
	private let producerQueue = DispatchQueue(
		label: "co.overpolish.keyframeless.audioplayer.producer", qos: .userInteractive)

	private let stateLock = NSLock()
	private var _stopped = false
	private var _pendingScheduled = 0
	private var _sourceTimeOfNextSample: Double

	private let prerollCount = 4

	static func start(clip: FCPXMLParser.AudioClip, fromSourceTime time: Double) async throws
		-> LivePlaybackSession
	{
		let resolved = try clip.resolvedURL()
		let asset = AVURLAsset(url: resolved.url)
		guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
			resolved.stopAccess()
			throw NSError(domain: "LivePlaybackSession", code: 1)
		}
		let (sampleRate, channels) = try await MultichannelAudioReader.trackFormat(track)
		let picked = MultichannelAudioReader.resolveChannels(
			clip.sourceChannels, trackChannels: channels)
		guard !picked.isEmpty else {
			resolved.stopAccess()
			throw NSError(domain: "LivePlaybackSession", code: 2)
		}

		let timescale = CMTimeScale(sampleRate)
		let remaining = max(0, clip.sourceDuration - (time - clip.sourceStart))
		let source = try MultichannelAudioReader.makeSource(
			asset: asset, track: track, sampleRate: sampleRate, channels: channels,
			timeRange: CMTimeRange(
				start: CMTime(seconds: time, preferredTimescale: timescale),
				duration: CMTime(seconds: remaining, preferredTimescale: timescale)))
		source.reader.startReading()

		guard
			let mono = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
				interleaved: false)
		else {
			resolved.stopAccess()
			throw NSError(domain: "LivePlaybackSession", code: 3)
		}

		var auInstances: [AVAudioUnit] = []
		for f in clip.auFilters ?? [] {
			let au = try await AudioUnitRenderer.instantiate(filter: f)
			auInstances.append(au)
		}

		let session = LivePlaybackSession(
			auNodes: auInstances, auFilters: clip.auFilters ?? [],
			reader: source.reader, readerOutput: source.output,
			monoFormat: mono, trackChannels: channels, trackSampleRate: sampleRate,
			pickedChannels: picked, volumeCurve: clip.volumeCurve,
			fadeIn: clip.fadeIn, fadeOut: clip.fadeOut,
			clipSourceStart: clip.sourceStart, clipSourceDuration: clip.sourceDuration,
			resolvedURL: resolved, sourceTimeStart: time)
		try session.startEngine()
		session.pump()
		return session
	}

	private init(
		auNodes: [AVAudioUnit], auFilters: [FCPXMLParser.AudioFilter],
		reader: AVAssetReader,
		readerOutput: AVAssetReaderTrackOutput, monoFormat: AVAudioFormat,
		trackChannels: Int, trackSampleRate: Double, pickedChannels: [Int],
		volumeCurve: [FCPXMLParser.VolumePoint]?,
		fadeIn: FCPXMLParser.FadeSpec?, fadeOut: FCPXMLParser.FadeSpec?,
		clipSourceStart: Double, clipSourceDuration: Double,
		resolvedURL: FCPXMLParser.AudioClip.ResolvedURL, sourceTimeStart: Double
	) {
		self.auNodes = auNodes
		self.auFilters = auFilters
		self.reader = reader
		self.readerOutput = readerOutput
		self.monoFormat = monoFormat
		self.trackChannels = trackChannels
		self.trackSampleRate = trackSampleRate
		self.pickedChannels = pickedChannels
		self.volumeCurve = volumeCurve
		self.fadeIn = fadeIn
		self.fadeOut = fadeOut
		self.clipSourceStart = clipSourceStart
		self.clipSourceDuration = clipSourceDuration
		self.resolvedURL = resolvedURL
		self._sourceTimeOfNextSample = sourceTimeStart
	}

	private func startEngine() throws {
		engine.attach(playerNode)
		for au in auNodes { engine.attach(au) }
		var previous: AVAudioNode = playerNode
		for au in auNodes {
			engine.connect(previous, to: au, format: monoFormat)
			previous = au
		}
		engine.connect(previous, to: engine.mainMixerNode, format: monoFormat)
		try engine.start()
		playerNode.play()
	}

	func stop() {
		stateLock.lock()
		if _stopped {
			stateLock.unlock()
			return
		}
		_stopped = true
		stateLock.unlock()
		playerNode.stop()
		if engine.isRunning { engine.stop() }
		for au in auNodes { engine.detach(au) }
		engine.detach(playerNode)
		reader.cancelReading()
		resolvedURL.stopAccess()
	}

	func elapsedSeconds() -> Double? {
		guard let last = playerNode.lastRenderTime,
			let playerTime = playerNode.playerTime(forNodeTime: last)
		else { return nil }
		return Double(playerTime.sampleTime) / playerTime.sampleRate
	}

	/// Drives live AU parameter automation. Called periodically from the
	/// owning `AudioPlayer`'s progress timer with the current source time.
	func updateAutomation(atSourceTime t: Double) {
		for (au, filter) in zip(auNodes, auFilters) {
			for override in filter.paramOverrides {
				guard let kfs = override.keyframes, kfs.count > 1 else { continue }
				let v = Keyframes.interpolateParam(kfs, at: t)
				AudioUnitSetParameter(
					au.audioUnit, AudioUnitParameterID(override.key),
					kAudioUnitScope_Global, 0, AudioUnitParameterValue(v), 0)
			}
		}
	}

	private func pump() {
		producerQueue.async { [weak self] in self?.pumpLoop() }
	}

	private func pumpLoop() {
		while true {
			stateLock.lock()
			if _stopped {
				stateLock.unlock()
				return
			}
			if _pendingScheduled >= prerollCount {
				stateLock.unlock()
				return
			}
			stateLock.unlock()

			guard let buffer = readNextMonoChunk() else { return }

			stateLock.lock()
			if _stopped {
				stateLock.unlock()
				return
			}
			_pendingScheduled += 1
			stateLock.unlock()

			playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
				guard let self else { return }
				self.stateLock.lock()
				self._pendingScheduled -= 1
				let stopped = self._stopped
				self.stateLock.unlock()
				if stopped { return }
				self.pump()
			}
		}
	}

	private func readNextMonoChunk() -> AVAudioPCMBuffer? {
		guard reader.status == .reading,
			let sb = readerOutput.copyNextSampleBuffer(),
			let block = CMSampleBufferGetDataBuffer(sb)
		else { return nil }

		var length = 0
		var dataPtr: UnsafeMutablePointer<Int8>?
		CMBlockBufferGetDataPointer(
			block, atOffset: 0, lengthAtOffsetOut: nil,
			totalLengthOut: &length, dataPointerOut: &dataPtr)
		guard let ptr = dataPtr else { return nil }
		let totalFloats = length / MemoryLayout<Float>.size
		let frames = totalFloats / trackChannels
		guard frames > 0,
			let buffer = AVAudioPCMBuffer(
				pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames))
		else { return nil }
		buffer.frameLength = AVAudioFrameCount(frames)
		let dst = buffer.floatChannelData![0]

		stateLock.lock()
		let chunkStartSourceTime = _sourceTimeOfNextSample
		stateLock.unlock()

		ptr.withMemoryRebound(to: Float.self, capacity: totalFloats) { src in
			MultichannelAudioReader.downmixToMono(
				src, dst: dst, frames: frames,
				trackChannels: trackChannels, pickedChannels: pickedChannels)
		}
		applyGainAndFades(
			dst: dst, frames: frames, chunkStartSourceTime: chunkStartSourceTime)

		stateLock.lock()
		_sourceTimeOfNextSample += Double(frames) / trackSampleRate
		stateLock.unlock()
		return buffer
	}

	private func applyGainAndFades(
		dst: UnsafeMutablePointer<Float>, frames: Int, chunkStartSourceTime: Double
	) {
		let hasFade = fadeIn != nil || fadeOut != nil
		let hasCurve = !(volumeCurve?.isEmpty ?? true)
		guard hasFade || hasCurve else { return }
		for i in 0..<frames {
			let t = chunkStartSourceTime + Double(i) / trackSampleRate
			var s = dst[i]
			if let curve = volumeCurve, !curve.isEmpty {
				s *= Float(pow(10.0, Keyframes.interpolateDB(curve, at: t) / 20.0))
			}
			if hasFade {
				s *= AudioPreparer.fadeMultiplier(
					clipLocal: t - clipSourceStart, duration: clipSourceDuration,
					fadeIn: fadeIn, fadeOut: fadeOut)
			}
			dst[i] = s
		}
	}
}
