/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import AudioToolbox
import Foundation

/// Owns a chain of raw v2 audio units and pulls samples through them.
///
/// Built once (loads effectState pre-Initialize, configures formats, wires
/// callbacks), then `renderChunk` can be called repeatedly with each input
/// chunk. Designed for streaming (live playback) and one-shot offline render
/// alike - see `AudioUnitRenderer.process` for the one-shot wrapper.
///
/// We can't use `AVAudioEngine` here because FCP-bundled AUs (EDEL Compressor,
/// Channel EQ, etc.) compute their DSP coefficients during
/// `AudioUnitInitialize` from the *current* parameter values, so the
/// persisted state has to be loaded via `kAudioUnitProperty_ClassInfo` BEFORE
/// `Initialize`. `AVAudioEngine` hides that boundary inside `engine.start()`
/// and ClassInfo applied before `start()` crashes the AU because stream
/// formats aren't set at the v2 layer yet.
///
/// Lifetime: the AUs are uninitialized + disposed in `deinit`. The chain
/// holds strong refs to the `SourceContext` objects whose pointers are passed
/// into each AU's render callback, so the contexts outlive any in-flight pull.
final class AudioUnitChain {

	let maxFramesPerSlice: AVAudioFrameCount = 4096
	private let nodes: [Node]
	private let sources: [SourceContext]
	private var renderedFrames: Int64 = 0

	var isEmpty: Bool { nodes.isEmpty }

	init(filters: [FCPXMLParser.AudioFilter], format: AVAudioFormat) throws {
		FCPAudioUnitLoader.ensureLoaded()

		var asbd = Self.streamFormat(for: format)
		var maxF = maxFramesPerSlice

		let built = filters.compactMap { filter in
			Self.instantiateNode(filter: filter, asbd: &asbd, maxFrames: &maxF)
		}
		self.nodes = built

		// First node pulls from the chain's `currentInput*` slots (rebound per
		// render). Later nodes pull from the previous AU via `AudioUnitRender`.
		self.sources = (0..<built.count).map { i -> SourceContext in
			let ctx = SourceContext()
			if i > 0 { ctx.upstream = built[i - 1].au }
			return ctx
		}
		for (node, source) in zip(built, sources) {
			Self.wireRenderCallback(node: node, source: source)
		}

		for node in built {
			try Self.loadStateAndInit(node: node)
		}
	}

	deinit {
		for node in nodes {
			AudioUnitUninitialize(node.au)
			AudioComponentInstanceDispose(node.au)
		}
	}

	/// Clears delay/reverb tails and time-based AU internal state without
	/// reloading effect parameters. Call before reusing a chain to render
	/// from a discontinuous source time (e.g. after a seek) so old samples
	/// don't bleed into the new playback position.
	func reset() {
		for node in nodes {
			AudioUnitReset(node.au, kAudioUnitScope_Global, 0)
		}
		renderedFrames = 0
	}

	/// Pulls `frames` samples through the chain. `input` and `output` must
	/// hold at least `frames` Float32 mono samples; `frames` must be ≤
	/// `maxFramesPerSlice`. Returns the `AudioUnitRender` status from the
	/// last (output) AU.
	@discardableResult
	func renderChunk(
		input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int
	) -> OSStatus {
		guard let lastAU = nodes.last?.au, let leaf = sources.first else { return noErr }
		leaf.input = input
		leaf.inputFrames = frames
		leaf.inputCursor = 0

		var bl = Self.makeAudioBufferList(
			data: UnsafeMutableRawPointer(output), frames: UInt32(frames))
		var ts = AudioTimeStamp()
		ts.mFlags = .sampleTimeValid
		ts.mSampleTime = Float64(renderedFrames)
		var flags: AudioUnitRenderActionFlags = []
		let status = AudioUnitRender(lastAU, &flags, &ts, 0, UInt32(frames), &bl)
		renderedFrames += Int64(frames)
		return status
	}

	func updateKeyframes(at sourceTime: Double) {
		for node in nodes {
			for override in node.filter.paramOverrides {
				guard let kfs = override.keyframes, kfs.count > 1 else { continue }
				let v = Keyframes.interpolateParam(kfs, at: sourceTime)
				AudioUnitSetParameter(
					node.au, AudioUnitParameterID(override.key),
					kAudioUnitScope_Global, 0, AudioUnitParameterValue(v), 0)
			}
		}
	}

	// MARK: - Build phases

	private static func streamFormat(for format: AVAudioFormat) -> AudioStreamBasicDescription {
		AudioStreamBasicDescription(
			mSampleRate: format.sampleRate,
			mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
			mBytesPerPacket: UInt32(format.channelCount) * 4,
			mFramesPerPacket: 1,
			mBytesPerFrame: UInt32(format.channelCount) * 4,
			mChannelsPerFrame: UInt32(format.channelCount),
			mBitsPerChannel: 32,
			mReserved: 0)
	}

	/// Creates an `AudioUnit` for `filter`, configures its stream formats and
	/// max-frames-per-slice. Returns nil when the AU isn't installable or any
	/// configuration step fails - the chain proceeds with the remaining
	/// filters so a single broken effect doesn't dry the whole chain.
	private static func instantiateNode(
		filter: FCPXMLParser.AudioFilter,
		asbd: inout AudioStreamBasicDescription,
		maxFrames: inout AVAudioFrameCount
	) -> Node? {
		var desc = AudioComponentDescription(
			componentType: filter.auType,
			componentSubType: filter.auSubtype,
			componentManufacturer: filter.auManufacturer,
			componentFlags: 0, componentFlagsMask: 0)
		guard let component = AudioComponentFindNext(nil, &desc) else {
			print("[AudioUnitChain] skipping '\(filter.name)' (not installed)")
			return nil
		}
		var au: AudioUnit?
		let createStatus = AudioComponentInstanceNew(component, &au)
		guard createStatus == noErr, let au else {
			print(
				"[AudioUnitChain] InstanceNew failed for '\(filter.name)': \(createStatus)")
			return nil
		}
		if !setStreamFormats(au: au, asbd: &asbd, name: filter.name)
			|| !setMaxFrames(au: au, maxFrames: &maxFrames, name: filter.name)
		{
			AudioComponentInstanceDispose(au)
			return nil
		}
		return Node(au: au, filter: filter)
	}

	private static func setStreamFormats(
		au: AudioUnit, asbd: inout AudioStreamBasicDescription, name: String
	) -> Bool {
		for scope: AudioUnitScope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
			let s = AudioUnitSetProperty(
				au, kAudioUnitProperty_StreamFormat, scope, 0,
				&asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
			if s != noErr {
				print(
					"[AudioUnitChain] StreamFormat scope=\(scope) failed for '\(name)': \(s)")
				return false
			}
		}
		return true
	}

	private static func setMaxFrames(
		au: AudioUnit, maxFrames: inout AVAudioFrameCount, name: String
	) -> Bool {
		let s = AudioUnitSetProperty(
			au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
			&maxFrames, UInt32(MemoryLayout<UInt32>.size))
		if s != noErr {
			print("[AudioUnitChain] MaxFramesPerSlice failed for '\(name)': \(s)")
			return false
		}
		return true
	}

	private static func wireRenderCallback(node: Node, source: SourceContext) {
		var cb = AURenderCallbackStruct(
			inputProc: renderCallback,
			inputProcRefCon: Unmanaged.passUnretained(source).toOpaque())
		let s = AudioUnitSetProperty(
			node.au, kAudioUnitProperty_SetRenderCallback,
			kAudioUnitScope_Input, 0, &cb,
			UInt32(MemoryLayout<AURenderCallbackStruct>.size))
		if s != noErr {
			print(
				"[AudioUnitChain] SetRenderCallback failed for '\(node.filter.name)': \(s)")
		}
	}

	/// Loads persisted state (when present), then initializes. Order matters:
	/// `AudioUnitInitialize` is what computes DSP coefficients from the
	/// current parameter values, so ClassInfo has to land first. Static
	/// `<param>` overrides only fall through when there's no effectState to
	/// load (otherwise we'd clobber the correctly-set internal coefficients
	/// with FCP's display-scale values).
	private static func loadStateAndInit(node: Node) throws {
		let stateLoaded = applyEffectState(node: node)
		let s = AudioUnitInitialize(node.au)
		if s != noErr {
			print("[AudioUnitChain] Initialize failed for '\(node.filter.name)': \(s)")
			throw NSError(
				domain: "AudioUnitChain", code: 7,
				userInfo: [NSLocalizedDescriptionKey: "Initialize failed: \(s)"])
		}
		if !stateLoaded {
			applyStaticParamOverrides(node: node)
		}
	}

	private static func applyEffectState(node: Node) -> Bool {
		guard let state = node.filter.effectState else { return false }
		return FCPEffectStateDecoder.apply(
			state: state, to: node.au, filterName: node.filter.name)
	}

	private static func applyStaticParamOverrides(node: Node) {
		for override in node.filter.paramOverrides where override.keyframes == nil {
			let status = AudioUnitSetParameter(
				node.au, AudioUnitParameterID(override.key),
				kAudioUnitScope_Global, 0,
				AudioUnitParameterValue(override.value), 0)
			if status != noErr {
				print(
					"[AudioUnitChain] param \(override.key)=\(override.value) "
						+ "set failed (\(status)) for \(node.filter.name)")
			}
		}
	}

	// MARK: - Render callback

	private static let renderCallback: AURenderCallback = {
		(refCon, _, inTimeStamp, _, frameCount, ioData) -> OSStatus in
		guard let outRaw = ioData?.pointee.mBuffers.mData
		else { return -1 }
		let src = Unmanaged<SourceContext>.fromOpaque(refCon).takeUnretainedValue()

		if let upstream = src.upstream {
			// Forward the host-supplied timestamp through. Time-based AUs
			// (Modulation Delay, Tremolo, AUVarispeed, etc.) drive their LFO
			// or sample position from `mSampleTime`; resetting it per chunk
			// causes audible phase jumps. The chain owns the global counter
			// in `renderedFrames` and passes it to the outermost call.
			var ts = inTimeStamp.pointee
			var flags: AudioUnitRenderActionFlags = []
			var bl = makeAudioBufferList(data: outRaw, frames: frameCount)
			return AudioUnitRender(upstream, &flags, &ts, 0, frameCount, &bl)
		}

		copyFromInputBuffer(src: src, out: outRaw, frameCount: Int(frameCount))
		return noErr
	}

	private static func copyFromInputBuffer(
		src: SourceContext, out: UnsafeMutableRawPointer, frameCount: Int
	) {
		let outFloat = out.assumingMemoryBound(to: Float.self)
		guard let input = src.input else {
			memset(outFloat, 0, frameCount * MemoryLayout<Float>.size)
			return
		}
		let remaining = src.inputFrames - src.inputCursor
		let toCopy = min(frameCount, max(0, remaining))
		if toCopy > 0 {
			memcpy(
				outFloat, input.advanced(by: src.inputCursor),
				toCopy * MemoryLayout<Float>.size)
		}
		if toCopy < frameCount {
			memset(
				outFloat.advanced(by: toCopy), 0,
				(frameCount - toCopy) * MemoryLayout<Float>.size)
		}
		src.inputCursor += toCopy
	}

	private static func makeAudioBufferList(
		data: UnsafeMutableRawPointer, frames: UInt32
	) -> AudioBufferList {
		AudioBufferList(
			mNumberBuffers: 1,
			mBuffers: AudioBuffer(
				mNumberChannels: 1,
				mDataByteSize: frames * UInt32(MemoryLayout<Float>.size),
				mData: data))
	}

	// MARK: - Internals

	private final class Node {
		let au: AudioUnit
		let filter: FCPXMLParser.AudioFilter
		init(au: AudioUnit, filter: FCPXMLParser.AudioFilter) {
			self.au = au
			self.filter = filter
		}
	}

	private final class SourceContext {
		var input: UnsafePointer<Float>?
		var inputFrames: Int = 0
		var inputCursor: Int = 0
		var upstream: AudioUnit?
	}
}
