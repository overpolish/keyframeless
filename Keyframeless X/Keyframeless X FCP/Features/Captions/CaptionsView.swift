/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CaptionsView: View {
	@ObservedObject var model: CaptionsModel
	@StateObject private var audioPlayer = AudioPlayer()
	@State private var dropState: DropState = .idle
	@State private var isTargeted = false
	@State private var timelineLoadID = UUID()

	enum DropState { case idle, denied, dropped }

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			if !model.dropItems.isEmpty {
				itemList
			}
			timelineArea
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
							: dropState == .denied
								? Color(nsColor: .error())
								: dropState == .dropped && model.audioClips.isEmpty
									? Color(nsColor: .warning())
									: Color.secondary.opacity(
										model.audioClips.isEmpty ? 0.4 : 0.15),
						style: StrokeStyle(
							lineWidth: 1.5, dash: model.audioClips.isEmpty ? [6, 4] : [])
					)
				if model.audioClips.isEmpty {
					VStack(spacing: 6) {
						Image(
							systemName: dropState == .denied
								? "xmark.circle"
								: dropState == .dropped
									? "exclamationmark.triangle" : "arrow.down.doc"
						)
						.font(.title)
						.foregroundStyle(emptyStateColor)
						Text(dropZoneLabel)
							.font(.title3)
							.foregroundStyle(emptyStateColor)
					}
					.blur(radius: isTargeted ? 3 : 0)
				} else {
					TimelineAxisView(
						duration: timelineDuration,
						format: model.projectFormat,
						useTimecode: model.useTimecode,
						clips: model.audioClips,
						selectedClips: $model.selectedClips,
						audioPlayer: audioPlayer
					)
					.id(timelineLoadID)
					.padding(.horizontal, 8)
					.padding(.bottom, 4)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.blur(radius: isTargeted ? 3 : 0)
				}
				FCPDropZoneView { doc in
					let clips = FCPXMLParser.audioClips(in: doc)
					model.audioClips = clips
					model.selectedClips = Set(clips.indices)
					model.dropItems = FCPXMLParser.topLevelItems(in: doc)
					let fmt = FCPXMLParser.projectFormat(in: doc) ?? .default
					model.projectFormat = fmt
					model.useTimecode = !fmt.fpsDisplay.isEmpty
					dropState = .dropped
					isTargeted = false
					timelineLoadID = UUID()
				} onDenied: {
					dropState = .denied
					model.audioClips = []
					model.selectedClips = []
					model.dropItems = []
					isTargeted = false
				} onTargeted: { targeted in
					isTargeted = targeted
				}
			}
			.frame(maxWidth: .infinity)
			.frame(minHeight: 80)
			HStack {
				Spacer()
				timeToggle
			}
			.padding(.top, 4)
		}
		.padding(.horizontal, KKPaddingMD)
	}

	private var emptyStateColor: Color {
		switch dropState {
		case .denied: return Color(nsColor: .error())
		case .dropped: return Color(nsColor: .warning())
		case .idle: return Color(nsColor: .timelineLabel())
		}
	}

	private var dropZoneLabel: String {
		switch dropState {
		case .idle: return "Drop FCP clips here"
		case .denied: return "Cannot drop library or event"
		case .dropped:
			return model.audioClips.isEmpty
				? "No dialogue found" : "\(model.audioClips.count) dialogue clips"
		}
	}

	private var timelineDuration: Double {
		model.projectFormat?.sequenceDuration ?? model.audioClips.map(\.end).max() ?? 0
	}

	private var timeToggle: some View {
		HStack(spacing: 2) {
			pillToggleOption("Timecode", value: true)
			pillToggleOption("Seconds", value: false)
		}
		.padding(3)
		.background(Capsule().fill(Color.white.opacity(0.08)))
		.disabled(model.audioClips.isEmpty || (model.projectFormat?.fpsDisplay.isEmpty ?? true))
	}

	private var itemList: some View {
		VStack(spacing: 2) {
			ForEach(Array(model.dropItems.enumerated()), id: \.offset) { _, item in
				HStack {
					Text(item.name)
						.font(.title2)
						.lineLimit(1)
						.opacity(dropState == .denied ? 0 : 1)
					Spacer()
					HStack(spacing: 1) {
						Text("\(model.selectedClips.count)")
							.foregroundStyle(Color(nsColor: .accent() ?? .blue))
						Text("/ \(model.audioClips.count) selected")
							.foregroundStyle(.secondary)
					}
					.font(.caption2)
					.padding(.trailing, 2)
					clipToolbar
				}
				.padding(.horizontal, KKPaddingLG)
			}
		}
	}

	private var clipToolbar: some View {
		let hasMain = model.audioClips.contains { !$0.isCompound }
		let hasCompound = model.audioClips.contains { $0.isCompound }
		return HStack(spacing: 0) {
			if hasMain {
				Button {
					model.selectedClips = Set(
						model.audioClips.indices.filter { !model.audioClips[$0].isCompound })
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
					}
				}
				.buttonStyle(.plain)
				toolbarDivider
			}
			if hasCompound {
				Button {
					model.selectedClips = Set(
						model.audioClips.indices.filter { model.audioClips[$0].isCompound })
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
					}
				}
				.buttonStyle(.plain)
				toolbarDivider
			}
			Button {
				model.selectedClips = Set(model.audioClips.indices)
			} label: {
				toolbarItem {
					HStack(spacing: 4) {
						Image(systemName: "checkmark.rectangle.stack.fill")
						Text("Select All")
					}
					.font(.caption2)
					.foregroundStyle(.secondary)
				}
			}
			.buttonStyle(.plain)
			toolbarDivider
			Button {
				model.selectedClips = []
			} label: {
				toolbarItem {
					HStack(spacing: 4) {
						Image(systemName: "rectangle.stack")
						Text("Deselect All")
					}
					.font(.caption2)
					.foregroundStyle(.secondary)
				}
			}
			.buttonStyle(.plain)
		}
		.disabled(model.audioClips.isEmpty)
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
			.contentShape(Rectangle())
	}

	private func pillToggleOption(_ label: String, value: Bool) -> some View {
		Button {
			model.useTimecode = value
		} label: {
			Text(label)
				.font(.system(size: 10, weight: .medium))
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background {
					if model.useTimecode == value {
						Capsule().fill(Color(nsColor: .accent()))
					}
				}
				.foregroundStyle(model.useTimecode == value ? .white : .secondary)
				.contentShape(Capsule())
		}
		.buttonStyle(.plain)
	}
}
