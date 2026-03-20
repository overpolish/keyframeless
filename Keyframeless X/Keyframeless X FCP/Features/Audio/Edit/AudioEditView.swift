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
	@State private var editingRowID: Int?
	@State private var clickMonitor: Any?

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
			clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
				if editingRowID != nil {
					let location = event.locationInWindow
					if let contentView = event.window?.contentView {
						let hitView = contentView.hitTest(location)
						if !(hitView is NSTextField || hitView is NSTextView) {
							event.window?.makeFirstResponder(nil)
						}
					}
				}
				return event
			}
		}
		.onDisappear {
			player.stop()
			if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
			clickMonitor = nil
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
				TimelineAxisView(
					duration: timelineDuration,
					format: model.projectFormat,
					useTimecode: model.useTimecode,
					clips: model.audioClips,
					selectedClips: editSelectedClips,
					dimmedIndices: transcribedIndices.isEmpty
						? Set(model.audioClips.indices) : untranscribedIndices,
					showWaveforms: false,
					hoveredClipIndex: $hoveredClipIndex,
					onClickDimmed: { index in
						model.selectedClips = [index]
						model.stage = .setup
					}
				)
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
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			ScrollShadowView {
				if transcribedClipGroups.isEmpty {
					EmptyTranscriptionPlaceholder()
				} else {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(transcribedClipGroups, id: \.clipIndex) { group in
							TranscribedClipSection(
								group: group,
								clips: model.audioClips,
								selectedClips: editSelectedClips,
								hoveredClipIndex: $hoveredClipIndex,
								player: player,
								editingRowID: $editingRowID,
								sentenceRowIDs: sentenceRowIDs
							) { rowID, editedWords in
								if let idx = rows.firstIndex(where: { $0.id == rowID }) {
									rows[idx].editedWords = editedWords
								}
							}
						}
					}
					.padding(KKPaddingMD)
				}
			}
			.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD + 4))
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.fill(Color.white.opacity(0.04))
			)
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
			)

			if !untranscribedRows.isEmpty {
				HStack {
					Text("Untranscribed Clips")
						.font(.title3)
						.foregroundStyle(.secondary)
					Spacer()
					Button {
						model.selectedClips = Set(untranscribedRows.map(\.clipIndex))
						model.stage = .setup
					} label: {
						Text("Transcribe All")
							.font(.system(size: 11))
					}
					.buttonStyle(.plain)
					.foregroundStyle(Color(nsColor: .accent() ?? .blue))
				}
				ScrollShadowView {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(untranscribedRows) { row in
							UntranscribedClipRow(
								clipName: row.clipName,
								clipIndex: row.clipIndex,
								isCompound: row.isCompound,
								isHighlighted: hoveredClipIndex == row.clipIndex,
								hoveredClipIndex: $hoveredClipIndex
							) {
								model.selectedClips = [row.clipIndex]
								model.stage = .setup
							}
						}
					}
					.padding(KKPaddingMD)
				}
				.frame(maxHeight: 100, alignment: .top)
				.fixedSize(horizontal: false, vertical: true)
				.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD + 4))
				.background(
					RoundedRectangle(cornerRadius: KKRadiusMD + 4)
						.fill(Color.white.opacity(0.04))
				)
				.overlay(
					RoundedRectangle(cornerRadius: KKRadiusMD + 4)
						.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
				)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var transcribedClipGroups: [TranscribedClipGroup] {
		var groups: [TranscribedClipGroup] = []
		for row in rows where row.isHeader && row.isTranscribed {
			let sentences = rows.filter { !$0.isHeader && $0.clipIndex == row.clipIndex }
			groups.append(
				TranscribedClipGroup(
					clipIndex: row.clipIndex,
					clipName: row.clipName,
					isCompound: row.isCompound,
					sentences: sentences
				))
		}
		return groups
	}

	private var untranscribedRows: [AudioEditRow] {
		rows.filter { $0.isHeader && !$0.isTranscribed }
	}

	private var timelineDuration: Double {
		model.projectFormat?.sequenceDuration ?? model.audioClips.map(\.end).max() ?? 0
	}

	private var untranscribedIndices: Set<Int> {
		Set(model.audioClips.indices).subtracting(transcribedIndices)
	}

	private var sentenceRowIDs: [Int] {
		rows.filter { !$0.isHeader && $0.isTranscribed }.map(\.id)
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

private struct EmptyTranscriptionPlaceholder: View {
	var body: some View {
		VStack(spacing: KKSpacingSM) {
			Image(systemName: "waveform.slash")
				.font(.title3)
				.foregroundStyle(.tertiary)
			Text("No transcribed clips")
				.font(.subheadline)
				.foregroundStyle(.tertiary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(KKPaddingLG)
	}
}
