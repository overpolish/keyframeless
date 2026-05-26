/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct SetupTimelineArea: View {
	@ObservedObject var model: AudioModel
	@ObservedObject var audioPlayer: AudioPlayer
	let dropState: AudioSetupView.DropState
	let isTargeted: Bool
	let timelineLoadID: UUID
	let onDrop: (XMLDocument) -> Void
	let onDenied: () -> Void
	let onTargeted: (Bool) -> Void

	var body: some View {
		VStack(spacing: 0) {
			ZStack {
				RoundedRectangle(cornerRadius: 8)
					.strokeBorder(
						borderColor,
						style: StrokeStyle(
							lineWidth: 1.5, dash: model.audioClips.isEmpty ? [6, 4] : [])
					)
				if model.audioClips.isEmpty {
					DropZoneEmptyState(dropState: dropState, isTargeted: isTargeted)
				} else {
					SetupTimelineContent(
						model: model,
						audioPlayer: audioPlayer,
						isTargeted: isTargeted,
						timelineLoadID: timelineLoadID
					)
				}
				FCPDropZoneView(
					onDocument: onDrop,
					onDenied: onDenied,
					onTargeted: onTargeted
				)
			}
			.frame(maxWidth: .infinity)
			.frame(minHeight: 80)
			TimelineFooterMessages(clips: model.audioClips)
				.padding(.top, KKSpacingMD)
			ClipCountDisplay(
				selectedCount: model.selectedClips.count,
				totalCount: model.audioClips.count
			)
			.padding(.top, KKSpacingMD)
		}
	}

	private var borderColor: Color {
		if isTargeted { return Color.kkAccent }
		if dropState == .denied { return Color.kkError }
		if dropState == .dropped && model.audioClips.isEmpty { return Color.kkWarning }
		return Color.secondary.opacity(model.audioClips.isEmpty ? 0.4 : 0.15)
	}
}

private struct SetupTimelineContent: View {
	@ObservedObject var model: AudioModel
	@ObservedObject var audioPlayer: AudioPlayer
	let isTargeted: Bool
	let timelineLoadID: UUID

	var body: some View {
		TimelineAxisView(
			duration: model.projectFormat?.sequenceDuration ?? model.audioClips.map(\.end).max()
				?? 0,
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
}
