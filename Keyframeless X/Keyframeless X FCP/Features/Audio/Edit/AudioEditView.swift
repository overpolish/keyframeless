/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AudioEditView: View {
	@ObservedObject var model: AudioModel
	@StateObject private var player = AudioPlayer()

	@State private var rows: [AudioEditRow] = []
	@State private var hoveredClipIndex: Int?

	private var editSelectedClips: Binding<Set<Int>> {
		Binding(
			get: { model.editSelectedClips ?? [] },
			set: { model.editSelectedClips = $0 }
		)
	}

	var body: some View {
		GeometryReader { geo in
			VStack(spacing: KKSpacingLG) {
				topRow
				timelineSection(height: geo.size.height * 0.2)
				transcriptionList
			}
		}
		.onAppear {
			if model.editSelectedClips == nil {
				model.editSelectedClips = transcribedIndices
			}
			rows = AudioEditRowBuilder.buildRows(
				clips: model.audioClips, format: model.projectFormat)
		}
		.onDisappear {
			player.stop()
		}
	}

	private var topRow: some View {
		HStack {
			if let item = model.dropItems.first {
				Text(item.name)
					.font(.title2)
					.lineLimit(1)
			}
			Spacer()
			ClipSelectionToolbar(
				clips: model.audioClips,
				selectedClips: editSelectedClips,
				allowedIndices: transcribedIndices
			)
		}
	}

	private func timelineSection(height: CGFloat) -> some View {
		VStack(spacing: 0) {
			ZStack {
				RoundedRectangle(cornerRadius: CGFloat(KKRadiusMD))
					.strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1.5)
				if transcribedIndices.isEmpty {
					EmptyTimelinePlaceholder()
				} else {
					TimelineAxisView(
						duration: timelineDuration,
						format: model.projectFormat,
						useTimecode: model.useTimecode,
						clips: model.audioClips,
						selectedClips: editSelectedClips,
						dimmedIndices: untranscribedIndices,
						showWaveforms: false,
						hoveredClipIndex: $hoveredClipIndex,
						onClickDimmed: { index in
							model.selectedClips = [index]
							model.stage = .setup
						}
					)
				}
			}
			.frame(height: height)
			.overlay(alignment: .bottomTrailing) {
				HelperText(
					"Click and drag to quickly select/deselect clips",
					systemImage: "pointer.arrow.motionlines"
				)
				.padding(.trailing, KKPaddingSM)
				.alignmentGuide(.bottom) { d in d[.top] - KKSpacingMD }
			}
			ClipCountDisplay(
				selectedCount: model.editSelectedClips?.count ?? 0,
				totalCount: transcribedIndices.count,
				emptyLabel: "No Transcriptions Found",
				selectedLabel: "Transcriptions Selected"
			)
			.padding(.top, KKSpacingMD)
		}
	}

	private var transcriptionList: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(rows) { row in
					if row.isHeader {
						if row.isTranscribed {
							TranscribedClipHeader(
								clipName: row.clipName,
								clipIndex: row.clipIndex,
								selectedClips: editSelectedClips
							)
						} else {
							UntranscribedClipRow(
								clipName: row.clipName,
								clipIndex: row.clipIndex,
								isHighlighted: hoveredClipIndex == row.clipIndex,
								hoveredClipIndex: $hoveredClipIndex
							) {
								model.selectedClips = [row.clipIndex]
								model.stage = .setup
							}
							.padding(.top, KKSpacingLG)
							.padding(.bottom, KKSpacingXS)
						}
					} else {
						SentenceRow(
							row: row,
							clip: model.audioClips[row.clipIndex],
							isHovered: hoveredClipIndex == row.clipIndex,
							player: player,
							hoveredClipIndex: $hoveredClipIndex
						)
					}
				}
			}
			.padding(KKPaddingMD)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var timelineDuration: Double {
		model.projectFormat?.sequenceDuration ?? model.audioClips.map(\.end).max() ?? 0
	}

	private var untranscribedIndices: Set<Int> {
		Set(model.audioClips.indices).subtracting(transcribedIndices)
	}

	private var transcribedIndices: Set<Int> {
		let store = TranscriptionStore.shared
		var result = Set<Int>()
		for i in model.audioClips.indices {
			if store.words(for: model.audioClips[i]) != nil {
				result.insert(i)
			}
		}
		return result
	}
}

private struct EmptyTimelinePlaceholder: View {
	var body: some View {
		VStack(spacing: KKSpacingLG) {
			Image(systemName: "waveform.slash")
				.font(.title)
				.foregroundStyle(Color(nsColor: .timelineLabel()))
			Text("No transcribed clips")
				.font(.title3)
				.foregroundStyle(Color(nsColor: .timelineLabel()))
		}
	}
}
