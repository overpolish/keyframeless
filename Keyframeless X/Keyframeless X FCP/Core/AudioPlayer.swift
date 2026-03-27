/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import Combine

@MainActor
final class AudioPlayer: ObservableObject {
	// Spacebar-to-stop support: each view (setup, edit) owns its own AudioPlayer
	// instance, so we track all live instances here to allow AxisDocumentView's
	// keyDown to stop whichever one is currently playing.
	private static var activeInstances = NSHashTable<AudioPlayer>.weakObjects()
	private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "avi"]

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

	private var audioPlayer: AVAudioPlayer?
	private var avPlayer: AVPlayer?
	private var stopWorkItem: DispatchWorkItem?
	private var progressTimer: Timer?
	private var scopedURL: URL?

	init() {
		Self.activeInstances.add(self)
	}

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
		if isPlaying(index: index) {
			stopWorkItem?.cancel()
			if let avPlayer {
				avPlayer.seek(
					to: CMTime(seconds: offset, preferredTimescale: 48000),
					toleranceBefore: .zero, toleranceAfter: .zero)
			} else if let audioPlayer {
				audioPlayer.currentTime = offset
			}
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
		avPlayer?.pause()
		avPlayer = nil
		audioPlayer?.stop()
		audioPlayer = nil
		playingIndex = nil
		currentTime = nil
		if let url = scopedURL {
			url.stopAccessingSecurityScopedResource()
			scopedURL = nil
		}
	}

	private func startPlaying(clip: FCPXMLParser.AudioClip, index: Int, from time: Double) {
		stop()
		guard let resolved = try? clip.resolvedURL() else { return }

		let isVideo = Self.videoExtensions.contains(resolved.url.pathExtension.lowercased())

		if isVideo {
			let playerItem = AVPlayerItem(url: resolved.url)
			let newPlayer = AVPlayer(playerItem: playerItem)
			newPlayer.seek(
				to: CMTime(seconds: time, preferredTimescale: 48000),
				toleranceBefore: .zero, toleranceAfter: .zero)
			newPlayer.play()
			avPlayer = newPlayer
		} else {
			guard let newPlayer = try? AVAudioPlayer(contentsOf: resolved.url) else {
				resolved.stopAccess()
				return
			}
			newPlayer.prepareToPlay()
			newPlayer.currentTime = time
			newPlayer.play()
			audioPlayer = newPlayer
		}

		if resolved.isSecurityScoped { scopedURL = resolved.url } else { resolved.stopAccess() }
		playingIndex = index
		currentTime = time
		progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
			[weak self] _ in
			MainActor.assumeIsolated {
				if let avp = self?.avPlayer {
					self?.currentTime = avp.currentTime().seconds
				} else {
					self?.currentTime = self?.audioPlayer?.currentTime
				}
			}
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
