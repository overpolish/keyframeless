/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import Combine

@MainActor
final class AudioPlayer: ObservableObject {
	@Published private(set) var playingIndex: Int?
	@Published private(set) var currentTime: Double?

	private var player: AVAudioPlayer?
	private var stopWorkItem: DispatchWorkItem?
	private var progressTimer: Timer?
	private var tmpAudioURL: URL?

	func isPlaying(index: Int) -> Bool {
		playingIndex == index
	}

	func toggle(clip: FCPXMLParser.AudioClip, index: Int) {
		stopWorkItem?.cancel()
		stopWorkItem = nil
		if isPlaying(index: index) {
			stop()
			return
		}
		startPlaying(clip: clip, index: index, from: clip.sourceStart)
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
		startPlaying(clip: clip, index: index, from: from)
		stopWorkItem?.cancel()
		scheduleStop(after: max(0, clampedTo - from))
	}

	func scrub(clip: FCPXMLParser.AudioClip, index: Int, progress: Double) {
		let offset = clip.sourceStart + progress * clip.sourceDuration
		if isPlaying(index: index), let player = player {
			stopWorkItem?.cancel()
			player.currentTime = offset
			currentTime = offset
			let remaining = clip.sourceDuration * (1 - progress)
			scheduleStop(after: max(0, remaining))
		} else {
			startPlaying(clip: clip, index: index, from: offset)
		}
	}

	func stop() {
		progressTimer?.invalidate()
		progressTimer = nil
		stopWorkItem?.cancel()
		stopWorkItem = nil
		player?.stop()
		player = nil
		playingIndex = nil
		currentTime = nil
		if let url = tmpAudioURL {
			try? FileManager.default.removeItem(at: url)
			tmpAudioURL = nil
		}
	}

	private func startPlaying(clip: FCPXMLParser.AudioClip, index: Int, from time: Double) {
		stop()
		guard let data = try? clip.data(),
			let newPlayer = try? AVAudioPlayer(data: data)
		else { return }
		newPlayer.prepareToPlay()
		newPlayer.currentTime = time
		newPlayer.play()
		player = newPlayer
		playingIndex = index
		currentTime = time
		progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
			[weak self] _ in
			MainActor.assumeIsolated { self?.currentTime = self?.player?.currentTime }
		}
		let remaining = clip.sourceDuration - (time - clip.sourceStart)
		scheduleStop(after: max(0, remaining))
	}

	private func scheduleStop(after delay: Double) {
		let work = DispatchWorkItem { [weak self] in self?.stop() }
		stopWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}
}
