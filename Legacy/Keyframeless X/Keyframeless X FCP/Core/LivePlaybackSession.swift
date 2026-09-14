/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// Owns the `AVAssetReader` producer and player node for one clip start. Lives
/// off the main actor. Stop is idempotent.
///
/// The engine itself belongs to `PlaybackEngine` and outlives every session -
/// starting one costs ~1s on Bluetooth, so it can't be per-clip.
///
/// Pipeline: reader → downmix to mono → gain/fade → `AudioUnitChain` (raw v2
/// AUs with state loaded pre-Initialize) → `AVAudioPlayerNode` → mainMixer.
/// The AU chain lives outside `AVAudioEngine` so FCP-bundled effects (EDEL
/// Compressor, Channel EQ, etc.) can have their persisted parameter state
/// loaded via `kAudioUnitProperty_ClassInfo` BEFORE `AudioUnitInitialize`,
/// which is what computes their DSP coefficients. See `AudioUnitChain`.
final class LivePlaybackSession: @unchecked Sendable {

	/// Clip-derived data needed by the per-sample gain stage. Bundled so the
	/// initializer and the `applyGainAndFades` site read from one cohesive
	/// struct rather than juggling a dozen optional fields.
	private struct ClipMixState {
		let volumeCurve: [FCPXMLParser.VolumePoint]?
		let fadeIn: FCPXMLParser.FadeSpec?
		let fadeOut: FCPXMLParser.FadeSpec?
		let outer: FCPXMLParser.OuterCompound?
		let clipSourceStart: Double
		let clipSourceDuration: Double
	}

	private let playerNode = AVAudioPlayerNode()
	private let auChain: AudioUnitChain?
	private let source: MultichannelAudioReader.MonoPickSource
	private let monoFormat: AVAudioFormat
	private let trackSampleRate: Double
	private let mix: ClipMixState
	private let resolvedURL: FCPXMLParser.AudioClip.ResolvedURL
	private let producerQueue = DispatchQueue(
		label: "com.keyframeless.audioplayer.producer", qos: .userInteractive)

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
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		guard !tracks.isEmpty else {
			resolved.stopAccess()
			throw NSError(domain: "LivePlaybackSession", code: 1)
		}
		var formats: [(sampleRate: Double, channels: Int)] = []
		for track in tracks {
			formats.append(try await MultichannelAudioReader.trackFormat(track))
		}
		let picks = MultichannelAudioReader.resolveFlatWeights(
			clip.channelWeights, trackChannelCounts: formats.map(\.channels))
		guard picks.contains(where: { !$0.isEmpty }) else {
			resolved.stopAccess()
			throw NSError(domain: "LivePlaybackSession", code: 2)
		}
		let sampleRate = formats[picks.firstIndex(where: { !$0.isEmpty })!].sampleRate

		let timescale = CMTimeScale(sampleRate)
		let remaining = max(0, clip.sourceDuration - (time - clip.sourceStart))
		let source: MultichannelAudioReader.MonoPickSource
		do {
			source = try MultichannelAudioReader.MonoPickSource(
				asset: asset, tracks: tracks, trackChannelCounts: formats.map(\.channels),
				picks: picks, sampleRate: sampleRate,
				timeRange: CMTimeRange(
					start: CMTime(seconds: time, preferredTimescale: timescale),
					duration: CMTime(seconds: remaining, preferredTimescale: timescale)))
		} catch {
			resolved.stopAccess()
			throw error
		}
		source.startReading()

		guard
			let mono = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
				interleaved: false)
		else {
			resolved.stopAccess()
			throw NSError(domain: "LivePlaybackSession", code: 3)
		}

		var chain: AudioUnitChain?
		if let filters = clip.auFilters, !filters.isEmpty {
			chain = try? AudioUnitChain(filters: filters, format: mono)
		}

		let mix = ClipMixState(
			volumeCurve: clip.volumeCurve,
			fadeIn: clip.fadeIn, fadeOut: clip.fadeOut,
			outer: clip.outer,
			clipSourceStart: clip.sourceStart,
			clipSourceDuration: clip.sourceDuration)
		let session = LivePlaybackSession(
			auChain: chain,
			source: source,
			monoFormat: mono, trackSampleRate: sampleRate,
			mix: mix,
			resolvedURL: resolved, sourceTimeStart: time)
		try session.startEngine()
		session.pump()
		return session
	}

	private init(
		auChain: AudioUnitChain?,
		source: MultichannelAudioReader.MonoPickSource,
		monoFormat: AVAudioFormat, trackSampleRate: Double,
		mix: ClipMixState,
		resolvedURL: FCPXMLParser.AudioClip.ResolvedURL, sourceTimeStart: Double
	) {
		self.auChain = auChain
		self.source = source
		self.monoFormat = monoFormat
		self.trackSampleRate = trackSampleRate
		self.mix = mix
		self.resolvedURL = resolvedURL
		self._sourceTimeOfNextSample = sourceTimeStart
	}

	private func startEngine() throws {
		try PlaybackEngine.shared.add(playerNode, format: monoFormat)
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
		PlaybackEngine.shared.remove(playerNode)
		source.cancelReading()
		resolvedURL.stopAccess()
	}

	/// Seconds between audio being handed to the engine and it reaching the
	/// speakers.
	///
	/// `elapsedSeconds` reports the player node's schedule position, so anything
	/// showing it as "where playback is" runs ahead of what you hear by this much
	/// - 160ms on Bluetooth output, which is very visible against a waveform.
	///
	/// `playerNode.outputPresentationLatency` alone: `engine.outputNode
	/// .presentationLatency` reports the SAME device buffer from the other end, so
	/// adding them double-counts it. An AU chain's own latency does add, since it
	/// delays the audio before it's ever scheduled.
	var presentationDelay: Double {
		(auChain?.latencySeconds ?? 0) + playerNode.outputPresentationLatency
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
		auChain?.updateKeyframes(at: t)
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
		guard let mono = source.nextMonoChunk(), !mono.isEmpty else { return nil }
		let frames = mono.count
		guard
			let buffer = AVAudioPCMBuffer(
				pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames))
		else { return nil }
		buffer.frameLength = AVAudioFrameCount(frames)
		let dst = buffer.floatChannelData![0]

		stateLock.lock()
		let chunkStartSourceTime = _sourceTimeOfNextSample
		stateLock.unlock()

		mono.withUnsafeBufferPointer { src in
			dst.update(from: src.baseAddress!, count: frames)
		}
		applyGainAndFades(
			dst: dst, frames: frames, chunkStartSourceTime: chunkStartSourceTime)
		if let chain = auChain, !chain.isEmpty {
			renderThroughAUChain(
				chain: chain, buffer: buffer, frames: frames,
				chunkStartSourceTime: chunkStartSourceTime)
		}

		stateLock.lock()
		_sourceTimeOfNextSample += Double(frames) / trackSampleRate
		stateLock.unlock()
		return buffer
	}

	/// Pulls the dry chunk through the AU chain in slices ≤ `maxFramesPerSlice`,
	/// writing the processed audio back into the same buffer.
	private func renderThroughAUChain(
		chain: AudioUnitChain, buffer: AVAudioPCMBuffer, frames: Int,
		chunkStartSourceTime: Double
	) {
		let dst = buffer.floatChannelData![0]
		let maxF = Int(chain.maxFramesPerSlice)
		guard
			let scratch = AVAudioPCMBuffer(
				pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames))
		else { return }
		scratch.frameLength = AVAudioFrameCount(frames)
		let src = scratch.floatChannelData![0]
		memcpy(src, dst, frames * MemoryLayout<Float>.size)

		var done = 0
		while done < frames {
			let want = min(maxF, frames - done)
			chain.updateKeyframes(
				at: chunkStartSourceTime + Double(done) / trackSampleRate)
			let status = chain.renderChunk(
				input: UnsafePointer(src.advanced(by: done)),
				output: dst.advanced(by: done),
				frames: want)
			if status != noErr {
				print(
					"[LivePlaybackSession] AU chain render failed at frame \(done): \(status)")
				break
			}
			done += want
		}
	}

	private func applyGainAndFades(
		dst: UnsafeMutablePointer<Float>, frames: Int, chunkStartSourceTime: Double
	) {
		let hasInnerFade = mix.fadeIn != nil || mix.fadeOut != nil
		let hasInnerCurve = !(mix.volumeCurve?.isEmpty ?? true)
		let hasOuter = mix.outer?.hasFade == true || mix.outer?.hasVolumeCurve == true
		guard hasInnerFade || hasInnerCurve || hasOuter else { return }
		for i in 0..<frames {
			let t = chunkStartSourceTime + Double(i) / trackSampleRate
			dst[i] *= AudioBufferProcessing.sampleGain(
				sourceTime: t,
				clipSourceStart: mix.clipSourceStart,
				clipSourceDuration: mix.clipSourceDuration,
				volumeCurve: mix.volumeCurve,
				fadeIn: mix.fadeIn, fadeOut: mix.fadeOut,
				outer: mix.outer)
		}
	}
}
