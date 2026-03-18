/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CaptionsView: View {
	@ObservedObject var model: CaptionsModel
	@StateObject private var audioPlayer = AudioPlayer()
	@State private var audioClips: [FCPXMLParser.AudioClip] = []
	@State private var didDrop = false
	@State private var isTargeted = false

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			Spacer()
			KKAlertRepresentable(
				text: "Hello from KKAlertView",
				icon: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil))
			KKSeparatorRepresentable(
				text: "Timer",
				icon: NSImage(systemSymbolName: "timer", accessibilityDescription: nil))
			FCPDragZoneView()
				.frame(maxWidth: .infinity)
				.frame(height: 44)
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
				Text(
					didDrop && audioClips.isEmpty
						? "No dialogue found"
						: audioClips.isEmpty ? "Drop FCP clips here" : "\(audioClips.count) clips"
				)
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			FCPDropZoneView { clips in
				audioClips = clips
				didDrop = true
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
							audioPlayer.toggle(clip: clip)
						} label: {
							Image(
								systemName: audioPlayer.playingURL == clip.url
									? "stop.fill" : "play.fill"
							)
							.font(.caption)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, KKPaddingMD)
			}
		}
	}
}
