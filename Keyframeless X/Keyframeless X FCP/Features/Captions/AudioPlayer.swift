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
		guard let data = try? resolveData(for: clip),
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

	private func resolveData(for clip: FCPXMLParser.AudioClip) throws -> Data {
		if let bookmark = clip.bookmark {
			var isStale = false
			if let scopedURL = try? URL(
				resolvingBookmarkData: bookmark,
				options: .withSecurityScope,
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			) {
				let accessing = scopedURL.startAccessingSecurityScopedResource()
				defer { if accessing { scopedURL.stopAccessingSecurityScopedResource() } }
				return try Data(contentsOf: scopedURL)
			}
		}
		guard let url = clip.url else { throw CocoaError(.fileNoSuchFile) }
		return try Data(contentsOf: url)
	}
}
