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
	@State private var dropItems: [FCPXMLParser.DropItem] = []
	@State private var dropState: DropState = .idle
	@State private var isTargeted = false
	@State private var useTimecode = true

	enum DropState { case idle, denied, dropped }

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			FCPDragZoneView()
				.frame(maxWidth: .infinity)
				.frame(height: 44)
			dropZone
			if let fmt = model.projectFormat {
				formatLabels(fmt)
			}
			if !dropItems.isEmpty {
				itemList
			}
			if !audioClips.isEmpty {
				timeToggle
				TimelineAxisView(
					duration: timelineDuration,
					format: model.projectFormat,
					useTimecode: useTimecode
				)
				.padding(.horizontal, KKPaddingMD)
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
				Image(systemName: dropState == .denied ? "xmark.circle" : "arrow.down.doc")
					.font(.title2)
					.foregroundStyle(dropState == .denied ? Color.red.opacity(0.7) : .secondary)
				Text(dropZoneLabel)
					.font(.caption)
					.foregroundStyle(dropState == .denied ? Color.red.opacity(0.7) : .secondary)
			}
			FCPDropZoneView { clips in
				audioClips = clips
				dropState = .dropped
				isTargeted = false
			} onFormat: { fmt in
				model.projectFormat = fmt
				useTimecode = !fmt.fpsDisplay.isEmpty
			} onItems: { items in
				dropItems = items
			} onDenied: {
				dropState = .denied
				isTargeted = false
			}
		}
		.frame(maxWidth: .infinity)
		.frame(minHeight: 80)
		.padding(.horizontal, KKPaddingMD)
	}

	private var dropZoneLabel: String {
		switch dropState {
		case .idle: return "Drop FCP clips here"
		case .denied: return "Cannot drop library or event"
		case .dropped:
			return audioClips.isEmpty ? "No dialogue found" : "\(audioClips.count) dialogue clips"
		}
	}

	private func formatLabels(_ fmt: FCPXMLParser.ProjectFormat) -> some View {
		VStack(spacing: 2) {
			Text(fmt.name)
			Text("\(fmt.width) x \(fmt.height)  ·  \(fmt.fpsDisplay)")
			Text("Duration: \(fmt.durationDisplay)")
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, KKPaddingMD)
	}

	private var timelineDuration: Double {
		model.projectFormat?.sequenceDuration ?? audioClips.map(\.end).max() ?? 0
	}

	private func formatClipTime(_ clip: FCPXMLParser.AudioClip) -> String {
		if useTimecode, let fmt = model.projectFormat {
			return "\(fmt.timecode(for: clip.start)) - \(fmt.timecode(for: clip.end))"
		}
		return String(format: "%.2fs - %.2fs", clip.start, clip.end)
	}

	private var timeToggle: some View {
		Picker("", selection: $useTimecode) {
			Text("Timecode").tag(true)
			Text("Seconds").tag(false)
		}
		.pickerStyle(.segmented)
		.padding(.horizontal, KKPaddingMD)
		.disabled(model.projectFormat?.fpsDisplay.isEmpty ?? true)
	}

	private var itemList: some View {
		VStack(spacing: 2) {
			ForEach(Array(dropItems.enumerated()), id: \.offset) { _, item in
				HStack {
					Text(item.name)
						.font(.caption)
						.lineLimit(1)
					Spacer()
					Text("\(item.dialogueCount) dialogue")
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
				.padding(.horizontal, KKPaddingMD)
			}
		}
	}

	private var clipList: some View {
		VStack(spacing: 4) {
			ForEach(Array(audioClips.enumerated()), id: \.offset) { _, clip in
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text(clip.name)
							.font(.caption)
							.lineLimit(1)
						Text(formatClipTime(clip))
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
