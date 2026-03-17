/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AVFoundation
import KeyframelessKit
import SwiftUI

struct CaptionsView: View {
	@ObservedObject var model: CaptionsModel
	@State private var audioClips: [FCPXMLParser.AudioClip] = []
	@State private var isTargeted = false
	@State private var player: AVAudioPlayer?
	@State private var playingURL: URL?

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			Spacer()
			KKAlertRepresentable(
				text: "Hello from KKAlertView",
				icon: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil))
			KKSeparatorRepresentable(
				text: "Timer",
				icon: NSImage(systemSymbolName: "timer", accessibilityDescription: nil))
			Button("Insert Title") {
				model.insertTitle()
			}
			Text("Timeline: \(model.timelineDuration)")
				.font(.system(.body, design: .monospaced))
				.foregroundStyle(.secondary)

			dropZone

			if !audioClips.isEmpty {
				clipList
			}

			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var dropZone: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 8)
				.strokeBorder(
					isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
					style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
				)
			VStack(spacing: 6) {
				Image(systemName: "arrow.down.doc")
					.font(.title2)
					.foregroundStyle(.secondary)
				Text(audioClips.isEmpty ? "Drop FCP clips here" : "\(audioClips.count) clips")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			FCPDropZoneView { clips in
				audioClips = clips
				isTargeted = false
			}
		}
		.frame(maxWidth: .infinity)
		.frame(minHeight: 80)
		.padding(.horizontal, KKPaddingMD)
	}

	private var clipList: some View {
		VStack(spacing: 4) {
			ForEach(Array(audioClips.enumerated()), id: \.offset) { _, clip in
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text(clip.name)
							.font(.caption)
							.lineLimit(1)
						Text(String(format: "%.2fs – %.2fs", clip.start, clip.end))
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
					Spacer()
					if clip.url != nil {
						Button {
							togglePlay(clip: clip)
						} label: {
							Image(systemName: playingURL == clip.url ? "stop.fill" : "play.fill")
								.font(.caption)
						}
						.buttonStyle(.plain)
					} else {
						Image(systemName: "questionmark.circle")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, KKPaddingMD)
			}
		}
	}

	private func togglePlay(clip: FCPXMLParser.AudioClip) {
		if playingURL == clip.url {
			player?.stop()
			player = nil
			playingURL = nil
			return
		}
		player?.stop()
		do {
			let audioData = try resolveAudioData(clip: clip)
			let newPlayer = try AVAudioPlayer(data: audioData)
			newPlayer.play()
			player = newPlayer
			playingURL = clip.url
		} catch {
			print("[AVAudio] error: \(error)")
			playingURL = nil
		}
	}

	private func resolveAudioData(clip: FCPXMLParser.AudioClip) throws -> Data {
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
