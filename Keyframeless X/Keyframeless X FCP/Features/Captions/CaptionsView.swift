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
	@State private var selectedClips: Set<Int> = []
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
							? Color(nsColor: .accent())
							: Color.secondary.opacity(audioClips.isEmpty ? 0.4 : 0.15),
						style: StrokeStyle(lineWidth: 1.5, dash: audioClips.isEmpty ? [6, 4] : [])
					)
				if audioClips.isEmpty {
					VStack(spacing: 6) {
						Image(systemName: dropState == .denied ? "xmark.circle" : "arrow.down.doc")
							.font(.title2)
							.foregroundStyle(
								dropState == .denied
									? Color(nsColor: .error()) : Color(nsColor: .timelineLabel()))
						Text(dropZoneLabel)
							.font(.caption)
							.foregroundStyle(
								dropState == .denied
									? Color(nsColor: .error()) : Color(nsColor: .timelineLabel()))
					}
				} else {
					TimelineAxisView(
						duration: timelineDuration,
						format: model.projectFormat,
						useTimecode: useTimecode,
						clips: audioClips,
						selectedClips: $selectedClips,
						audioPlayer: audioPlayer
					)
					.id(timelineLoadID)
					.padding(.horizontal, 8)
					.padding(.bottom, 4)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
				FCPDropZoneView { clips in
					audioClips = clips
					selectedClips = Set(clips.indices)
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

	private var clipToolbar: some View {
		let hasMain = audioClips.contains { !$0.isCompound }
		let hasCompound = audioClips.contains { $0.isCompound }
		return HStack(spacing: 0) {
			toolbarItem {
				HStack(spacing: 1) {
					Text("\(selectedClips.count)")
						.foregroundStyle(Color(nsColor: .accent() ?? .blue))
					Text("/ \(audioClips.count) selected")
						.foregroundStyle(.secondary)
				}
				.font(.caption2)
			}
			if hasMain {
				toolbarDivider
				Button {
					selectedClips = Set(audioClips.indices.filter { !audioClips[$0].isCompound })
				} label: {
					toolbarItem {
						HStack(spacing: 4) {
							Circle()
								.fill(Color(nsColor: .accent() ?? .blue))
								.frame(width: 6, height: 6)
							Text("Main")
								.font(.caption2)
								.foregroundStyle(.secondary)
						}
						.contentShape(Rectangle())
					}
				}
				.buttonStyle(.plain)
			}
			if hasCompound {
				toolbarDivider
				Button {
					selectedClips = Set(audioClips.indices.filter { audioClips[$0].isCompound })
				} label: {
					toolbarItem {
						HStack(spacing: 4) {
							Circle()
								.fill(Color(nsColor: .warning() ?? .yellow))
								.frame(width: 6, height: 6)
							Text("Compound")
								.font(.caption2)
								.foregroundStyle(.secondary)
						}
						.contentShape(Rectangle())
					}
				}
				.buttonStyle(.plain)
			}
			toolbarDivider
			Button {
				selectedClips = Set(audioClips.indices)
			} label: {
				toolbarItem {
					Label("Select All", systemImage: "checkmark.rectangle.stack.fill")
						.font(.caption2)
						.foregroundStyle(.secondary)
						.contentShape(Rectangle())
				}
			}
			.buttonStyle(.plain)
			toolbarDivider
			Button {
				selectedClips = []
			} label: {
				toolbarItem {
					Label("Deselect All", systemImage: "rectangle.stack")
						.font(.caption2)
						.foregroundStyle(.secondary)
						.contentShape(Rectangle())
				}
			}
			.buttonStyle(.plain)
		}
		.background(RoundedRectangle(cornerRadius: 999).fill(Color.white.opacity(0.06)))
		.overlay(
			RoundedRectangle(cornerRadius: 999).strokeBorder(
				Color.secondary.opacity(0.2), lineWidth: 1))
	}

	private var toolbarDivider: some View {
		Rectangle()
			.fill(Color.secondary.opacity(0.2))
			.frame(width: 1, height: 14)
	}

	private func toolbarItem<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		content()
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
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
					clipToolbar
				}
				.padding(.horizontal, KKPaddingLG)
			}
		}
	}

	private var clipList: some View {
		VStack(spacing: 4) {
			ForEach(Array(audioClips.enumerated()), id: \.offset) { index, clip in
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
							audioPlayer.toggle(clip: clip, index: index)
						} label: {
							Image(
								systemName: audioPlayer.isPlaying(index: index)
									? "stop.fill" : "play.fill"
							)
							.font(.caption)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 8)
			}
		}
	}
}
