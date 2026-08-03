/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// One process-wide `AVAudioEngine`, kept running between clips.
///
/// `AVAudioEngine.start()` activates the output device, and on Bluetooth that
/// route setup costs ~1s. A session per scrub meant a fresh engine per scrub,
/// so every click paid it - the seek and decode behind it are only ~3ms. Start
/// once, leave it running, and a scrub costs what the audio actually costs.
///
/// Player nodes attach and detach per session; that part is cheap. The engine
/// stops itself once nothing has played for a while, so an idle extension isn't
/// holding the audio device open forever.
final class PlaybackEngine: @unchecked Sendable {
	static let shared = PlaybackEngine()

	/// How long to keep the device open after the last clip stops. Long enough
	/// that clicking around a timeline never pays the start cost twice, short
	/// enough that leaving the tab open doesn't hold the device.
	private let idleTimeout: TimeInterval = 60

	private let lock = NSLock()
	private let engine = AVAudioEngine()
	private var idleWork: DispatchWorkItem?
	private var liveNodes = 0

	private init() {}

	/// Attaches and connects `node`, starting the engine if it isn't already.
	func add(_ node: AVAudioPlayerNode, format: AVAudioFormat) throws {
		lock.lock()
		defer { lock.unlock() }
		idleWork?.cancel()
		idleWork = nil
		engine.attach(node)
		// Per-clip format: the main mixer converts, so clips at different sample
		// rates can share the one engine.
		engine.connect(node, to: engine.mainMixerNode, format: format)
		liveNodes += 1
		if !engine.isRunning {
			try engine.start()
		}
	}

	func remove(_ node: AVAudioPlayerNode) {
		lock.lock()
		defer { lock.unlock() }
		engine.detach(node)
		liveNodes = max(0, liveNodes - 1)
		guard liveNodes == 0 else { return }
		let work = DispatchWorkItem { [weak self] in self?.stopIfIdle() }
		idleWork = work
		DispatchQueue.global(qos: .utility).asyncAfter(
			deadline: .now() + idleTimeout, execute: work)
	}

	private func stopIfIdle() {
		lock.lock()
		defer { lock.unlock() }
		guard liveNodes == 0, engine.isRunning else { return }
		engine.stop()
	}
}
