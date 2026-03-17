/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import Combine

@MainActor
final class AudioPlayer: ObservableObject {
	@Published private(set) var playingURL: URL?

	private var player: AVAudioPlayer?
	private var stopWorkItem: DispatchWorkItem?

	func toggle(clip: FCPXMLParser.AudioClip) {
		stopWorkItem?.cancel()
		stopWorkItem = nil
		if playingURL == clip.url {
			stop()
			return
		}
		stop()
		guard let data = try? clip.data(),
			let newPlayer = try? AVAudioPlayer(data: data)
		else { return }
		newPlayer.prepareToPlay()
		newPlayer.currentTime = clip.sourceStart
		newPlayer.play()
		player = newPlayer
		playingURL = clip.url
		let work = DispatchWorkItem { [weak self] in self?.stop() }
		stopWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + clip.sourceDuration, execute: work)
	}

	func stop() {
		player?.stop()
		player = nil
		playingURL = nil
	}
}
