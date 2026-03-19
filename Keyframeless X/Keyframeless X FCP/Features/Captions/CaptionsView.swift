/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CaptionsView: View {
	@ObservedObject var model: CaptionsModel
	@StateObject private var audioPlayer = AudioPlayer()
	@StateObject private var whisperManager = WhisperModelManager()
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
			WhisperModelPickerView(manager: whisperManager)
				.padding(.horizontal, KKPaddingMD)
			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var timelineArea: some View {
		VStack(spacing: 0) {
			ZStack {
				RoundedRectangle(cornerRadius: 8)
					.strokeBorder(
						dropZoneBorderColor,
						style: StrokeStyle(
							lineWidth: 1.5, dash: model.audioClips.isEmpty ? [6, 4] : [])
					)
				if model.audioClips.isEmpty {
					DropZoneEmptyState(dropState: dropState, isTargeted: isTargeted)
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
					.padding(.horizontal, KKPaddingLG)
					.padding(.bottom, KKSpacingSM)
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
					isTargeted = false
				} onTargeted: { targeted in
					isTargeted = targeted
				}
			}
			.frame(maxWidth: .infinity)
			.frame(minHeight: 80)
			HStack {
				HelperText(
					"Click and drag to quickly select/deselect clips.",
					systemImage: "pointer.arrow.motionlines")
				Spacer()
				PillToggle(
					selection: $model.useTimecode,
					options: [("Timecode", true), ("Seconds", false)]
				)
				.disabled(
					model.audioClips.isEmpty || (model.projectFormat?.fpsDisplay.isEmpty ?? true))
			}
			.padding(.top, KKSpacingSM)
			ClipCountDisplay(
				selectedCount: model.selectedClips.count,
				totalCount: model.audioClips.count
			)
			.padding(.horizontal, KKPaddingLG)
			.padding(.top, KKSpacingMD)
		}
		.padding(.horizontal, KKPaddingMD)
	}

	private var dropZoneBorderColor: Color {
		if isTargeted { return Color(nsColor: .accent()) }
		if dropState == .denied { return Color(nsColor: .error()) }
		if dropState == .dropped && model.audioClips.isEmpty { return Color(nsColor: .warning()) }
		return Color.secondary.opacity(model.audioClips.isEmpty ? 0.4 : 0.15)
	}

	private var timelineDuration: Double {
		model.projectFormat?.sequenceDuration ?? model.audioClips.map(\.end).max() ?? 0
	}

	private var itemList: some View {
		VStack(spacing: KKSpacingXS) {
			ForEach(Array(model.dropItems.enumerated()), id: \.offset) { _, item in
				CaptionItemRow(
					name: item.name,
					isHidden: dropState == .denied,
					clips: model.audioClips,
					selectedClips: $model.selectedClips
				)
			}
		}
	}
}
