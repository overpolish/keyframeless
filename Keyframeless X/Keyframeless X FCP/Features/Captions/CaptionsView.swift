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
	@State private var timelineLoadID = UUID()

	enum DropState { case idle, denied, dropped }

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			FCPDragZoneView()
				.frame(maxWidth: .infinity)
				.frame(height: 44)
			if let fmt = model.projectFormat {
				formatLabels(fmt)
			}
			if !dropItems.isEmpty {
				itemList
			}
			timelineArea
			if !audioClips.isEmpty {
				clipList
			}
			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var timelineArea: some View {
		VStack(spacing: 0) {
			ZStack {
				RoundedRectangle(cornerRadius: 8)
					.strokeBorder(
						isTargeted
							? Color.green
							: Color.secondary.opacity(audioClips.isEmpty ? 0.4 : 0.15),
						style: StrokeStyle(lineWidth: 1.5, dash: audioClips.isEmpty ? [6, 4] : [])
					)
				if audioClips.isEmpty {
					VStack(spacing: 6) {
						Image(systemName: dropState == .denied ? "xmark.circle" : "arrow.down.doc")
							.font(.title2)
							.foregroundStyle(
								// TODO error color
								dropState == .denied ? Color.red.opacity(0.7) : .secondary)
						Text(dropZoneLabel)
							.font(.caption)
							.foregroundStyle(
								// TODO error color
								dropState == .denied ? Color.red.opacity(0.7) : .secondary)
					}
				} else {
					TimelineAxisView(
						duration: timelineDuration,
						format: model.projectFormat,
						useTimecode: useTimecode
					)
					.id(timelineLoadID)
					.padding(.horizontal, 8)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
				FCPDropZoneView { clips in
					audioClips = clips
					dropState = .dropped
					isTargeted = false
					timelineLoadID = UUID()
				} onFormat: { fmt in
					model.projectFormat = fmt
					useTimecode = !fmt.fpsDisplay.isEmpty
				} onItems: { items in
					dropItems = items
				} onDenied: {
					dropState = .denied
					isTargeted = false
				} onTargeted: { targeted in
					isTargeted = targeted
				}
			}
			.frame(maxWidth: .infinity)
			.frame(minHeight: 80)
			if !audioClips.isEmpty {
				HStack {
					Spacer()
					timeToggle
				}
				.padding(.top, 4)
			}
		}
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
		HStack(spacing: 2) {
			pillToggleOption("Timecode", value: true)
			pillToggleOption("Seconds", value: false)
		}
		.padding(3)
		.background(Capsule().fill(Color.white.opacity(0.08)))
		.disabled(model.projectFormat?.fpsDisplay.isEmpty ?? true)
	}

	private func pillToggleOption(_ label: String, value: Bool) -> some View {
		Button {
			useTimecode = value
		} label: {
			Text(label)
				.font(.system(size: 10, weight: .medium))
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background {
					if useTimecode == value {
						Capsule().fill(Color(nsColor: .accent()))
					}
				}
				.foregroundStyle(useTimecode == value ? .white : .secondary)
		}
		.buttonStyle(.plain)
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
