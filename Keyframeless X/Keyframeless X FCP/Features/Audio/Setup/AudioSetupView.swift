/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AudioSetupView: View {
	@ObservedObject var model: AudioModel
	@ObservedObject var whisperManager: WhisperModelManager
	var onProcess: (_ replaceAll: Bool) -> Void
	@StateObject private var audioPlayer = AudioPlayer()
	@State private var dropState: DropState = .idle
	@State private var isTargeted = false
	@State private var timelineLoadID = UUID()

	enum DropState { case idle, denied, dropped }

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			topRow
			timelineArea
				.frame(maxHeight: .infinity)
				.layoutPriority(1)
			HStack(alignment: .top, spacing: KKSpacingLG) {
				WhisperModelPickerView(manager: whisperManager)
				WhisperLanguagePickerView(manager: whisperManager)
					.frame(maxHeight: .infinity)
				WhisperTermsView(manager: whisperManager)
					.frame(maxHeight: .infinity)
			}
			.frame(maxHeight: .infinity)
			HStack(spacing: KKSpacingMD) {
				ProcessButton(
					disabled: processDisabled,
					action: { onProcess(true) }
				)
				RetranscribeButton(
					disabled: processDisabled,
					action: { onProcess(false) }
				)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onDisappear { audioPlayer.stop() }
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
						audioPlayer: audioPlayer,
						showWaveforms: true
					)
					.id(timelineLoadID)
					.padding(.bottom, KKSpacingSM)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.blur(radius: isTargeted ? 3 : 0)
				}
				FCPDropZoneView { doc in
					let clips = FCPXMLParser.audioClips(in: doc)
					model.audioClips = clips
					model.selectedClips = Set(clips.indices)
					model.editSelectedClips = nil
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
					model.editSelectedClips = nil
					isTargeted = false
				} onTargeted: { targeted in
					isTargeted = targeted
				}
			}
			.frame(maxWidth: .infinity)
			.frame(minHeight: 80)
			.overlay(alignment: .bottomTrailing) {
				HelperText(
					"Click and drag to quickly select/deselect clips",
					systemImage: "pointer.arrow.motionlines"
				)
				.padding(.trailing, KKPaddingSM)
				.alignmentGuide(.bottom) { d in d[.top] - KKSpacingMD }
			}
			ClipCountDisplay(
				selectedCount: model.selectedClips.count,
				totalCount: model.audioClips.count
			)
			.padding(.top, KKSpacingMD)
		}
	}

	private var processDisabled: Bool {
		model.selectedClips.isEmpty
			|| whisperManager.selectedModel == nil
			|| whisperManager.downloadingModel != nil
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

	private var topRow: some View {
		HStack {
			if let item = model.dropItems.first {
				Text(item.name)
					.font(.title2)
					.lineLimit(1)
					.opacity(dropState == .denied ? 0 : 1)
			}
			Spacer()
			ClipSelectionToolbar(clips: model.audioClips, selectedClips: $model.selectedClips)
		}
	}
}
