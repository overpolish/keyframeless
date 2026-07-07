/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlayer: ObservableObject {
	// Spacebar-to-stop support: each view (setup, edit) owns its own AudioPlayer
	// instance, so we track all live instances here to allow AxisDocumentView's
	// keyDown to stop whichever one is currently playing.
	private static var activeInstances = NSHashTable<AudioPlayer>.weakObjects()

	static var isAnyPlaying: Bool {
		activeInstances.allObjects.contains { $0.playingIndex != nil }
	}

	static func stopAll() {
		for instance in activeInstances.allObjects {
			instance.stop()
		}
	}

	@Published private(set) var playingIndex: Int?
	private(set) var currentTime: Double? {
		didSet { currentTimeSubject.send(currentTime) }
	}
	let currentTimeSubject = PassthroughSubject<Double?, Never>()

	private var session: LivePlaybackSession?
	private var startTask: Task<Void, Never>?
	private var stopWorkItem: DispatchWorkItem?
	private var progressTimer: Timer?
	private var startSourceTime: Double = 0

	init() {
		Self.activeInstances.add(self)
	}

	func isPlaying(index: Int) -> Bool { playingIndex == index }

	func toggle(clip: FCPXMLParser.AudioClip, index: Int) {
		stopWorkItem?.cancel()
		stopWorkItem = nil
		if isPlaying(index: index) {
			stop()
			return
		}
		startPlaying(clip: clip, index: index, from: clip.sourceStart, stopAfter: nil)
	}

	func toggleRange(clip: FCPXMLParser.AudioClip, index: Int, from: Double, to: Double) {
		stopWorkItem?.cancel()
		stopWorkItem = nil
		if isPlaying(index: index) {
			stop()
			return
		}
		let clipEnd = clip.sourceStart + clip.sourceDuration
		let clampedTo = min(clipEnd, to)
		startPlaying(clip: clip, index: index, from: from, stopAfter: max(0, clampedTo - from))
	}

	func scrub(clip: FCPXMLParser.AudioClip, index: Int, progress: Double) {
		let offset = clip.sourceStart + progress * clip.sourceDuration
		startPlaying(clip: clip, index: index, from: offset, stopAfter: nil)
	}

	func stop() {
		startTask?.cancel()
		startTask = nil
		progressTimer?.invalidate()
		progressTimer = nil
		stopWorkItem?.cancel()
		stopWorkItem = nil
		session?.stop()
		session = nil
		playingIndex = nil
		currentTime = nil
	}

	private func startPlaying(
		clip: FCPXMLParser.AudioClip, index: Int, from time: Double, stopAfter: Double?
	) {
		stop()
		playingIndex = index
		currentTime = time
		startSourceTime = time

		startTask = Task { [weak self] in
			guard let self else { return }
			do {
				let newSession = try await LivePlaybackSession.start(
					clip: clip, fromSourceTime: time)
				if Task.isCancelled {
					newSession.stop()
					return
				}
				await MainActor.run {
					guard self.playingIndex == index else {
						newSession.stop()
						return
					}
					self.session = newSession
					self.progressTimer = Timer.scheduledTimer(
						withTimeInterval: 1.0 / 30.0, repeats: true
					) { [weak self] _ in
						MainActor.assumeIsolated { self?.tickCurrentTime() }
					}
					let remaining = stopAfter ?? (clip.sourceDuration - (time - clip.sourceStart))
					self.scheduleStop(after: max(0, remaining))
				}
			} catch {
				print("[AudioPlayer] start failed: \(error)")
				await MainActor.run { self.stop() }
			}
		}
	}

	private func tickCurrentTime() {
		guard let session, let elapsed = session.elapsedSeconds() else { return }
		let absoluteTime = startSourceTime + elapsed
		currentTime = absoluteTime
		session.updateAutomation(atSourceTime: absoluteTime)
	}

	private func scheduleStop(after delay: Double) {
		let work = DispatchWorkItem { [weak self] in self?.stop() }
		stopWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}
}
