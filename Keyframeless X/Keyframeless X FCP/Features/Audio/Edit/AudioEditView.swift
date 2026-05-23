/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import KeyframelessKit
import SwiftUI

struct AudioEditView: View {
	@ObservedObject var model: AudioModel
	@StateObject private var player = AudioPlayer()

	@State private var rows: [AudioEditRow] = []
	@State private var hoveredClipIndex: Int?
	@State private var editingRowID: Int?
	@State private var clickMonitor: Any?
	@State private var rowFrames: [Int: CGRect] = [:]
	@State private var viewportHeight: CGFloat = 0
	@State private var srtHasOverlaps: Bool = false
	@State private var srtOverlapRegions: [CaptionBuilder.OverlapRegion] = []

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
				timelineSection(height: geo.size.height * 0.1)
				transcriptionList
			}
		}
		.onAppear {
			if model.editSelectedClips == nil {
				model.editSelectedClips = transcribedIndices
			}
			rows = AudioEditRowBuilder.buildRows(
				clips: model.audioClips, format: model.projectFormat)
			updateSRTOverlaps()
			// On non-text-field clicks, redirect first responder to the timeline's
			// AxisDocumentView so spacebar can stop playback. Must happen during a
			// real mouseDown — see TimelineFirstResponder comment for details.
			clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
				guard let window = event.window else { return event }
				let hitView = window.contentView?.hitTest(event.locationInWindow)
				let isEditableText =
					hitView is NSTextField
					|| (hitView as? NSTextView)?.isEditable == true
				if !isEditableText {
					TimelineFirstResponder.claim(in: window)
				}
				return event
			}
		}
		.onReceive(
			model.objectWillChange
				.debounce(for: .milliseconds(300), scheduler: RunLoop.main)
		) { _ in
			updateSRTOverlaps()
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
					overlapRegions: srtOverlapRegions,
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
					String(localized: "Click and drag to quickly select/deselect clips"),
					systemImage: "cursorarrow.motionlines"
				)
				.padding(.trailing, KKPaddingSM)
				.alignmentGuide(.bottom) { d in d[.top] - KKSpacingMD }
			}
		}
	}

	private var transcriptionList: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			ClipCountDisplay(
				selectedCount: model.editSelectedClips?.count ?? 0,
				totalCount: transcribedIndices.count,
				emptyLabel: String(localized: "No Transcriptions Found"),
				selectedLabel: String(localized: "Transcriptions Selected")
			)
			HStack(alignment: .top, spacing: KKSpacingLG) {
				VStack(alignment: .leading, spacing: KKSpacingLG) {
					HStack(alignment: .firstTextBaseline) {
						Text("Transcriptions")
							.font(.title3)
							.foregroundStyle(.secondary)
							.padding(.horizontal, KKPaddingSM)
						Spacer()
						if let selected = model.editSelectedClips, !selected.isEmpty {
							Button {
								model.selectedClips = selected
								model.stage = .setup
							} label: {
								Label(
									"Reprocess Selected",
									systemImage: "arrow.trianglehead.2.counterclockwise"
								)
								.font(.system(size: 11))
							}
							.buttonStyle(.plain)
							.foregroundStyle(Color.kkAccent)
						}
					}

					if transcribedClipGroups.isEmpty {
						EmptyTranscriptionPlaceholder()
							.kkPanel()
					} else {
						ScrollShadowView {
							ScrollViewReader { proxy in
								LazyVStack(alignment: .leading, spacing: 0) {
									HStack {
										HelperText(
											String(
												localized: "Right-click to add/remove manual breaks"
											),
											systemImage:
												"square.fill.and.line.vertical.and.square.fill"
										)
										Spacer()
										BreakLegend()
									}
									.padding(.all, KKSpacingMD)
									ForEach(transcribedClipGroups, id: \.clipIndex) { group in
										TranscribedClipSection(
											group: group,
											clips: model.audioClips,
											selectedClips: editSelectedClips,
											hoveredClipIndex: $hoveredClipIndex,
											player: player,
											editingRowID: $editingRowID,
											sentenceRowIDs: sentenceRowIDs,
											predictedBreaks: predictedBreaksForGroup(group),
											onSentenceEdit: { rowID, editedWords in
												if let idx = rows.firstIndex(where: {
													$0.id == rowID
												}) {
													rows[idx].editedWords = editedWords
												}
											},
											onBreakToggle: { rowID, breaks in
												if let idx = rows.firstIndex(where: {
													$0.id == rowID
												}) {
													rows[idx].captionBreaks = breaks
												}
												updateSRTOverlaps()
											}
										)
									}
								}
								.padding(KKPaddingMD)
								Color.clear
									.frame(height: 0)
									.onChange(of: editingRowID) {
										guard let id = editingRowID else { return }
										if let frame = rowFrames[id] {
											let isAbove = frame.minY < 0
											let isBelow = frame.maxY > viewportHeight
											guard isAbove || isBelow else { return }
										}
										withAnimation {
											proxy.scrollTo(id, anchor: .center)
										}
									}
							}
						}
						.coordinateSpace(name: "editScroll")
						.onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
						.background(
							GeometryReader { geo in
								Color.clear.onAppear { viewportHeight = geo.size.height }
									.onChange(of: geo.size.height) {
										viewportHeight = geo.size.height
									}
							}
						)
						.kkPanel()
					}

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
							.foregroundStyle(Color.kkAccent)
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
						.kkPanel()
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				AudioExportOptionsSidebar(
					model: model, rows: rows, srtHasOverlaps: srtHasOverlaps
				)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
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

	private func updateSRTOverlaps() {
		srtOverlapRegions = model.srtOverlapRegions(from: rows)
		srtHasOverlaps = !srtOverlapRegions.isEmpty
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

	private func predictedBreaksForGroup(_ group: TranscribedClipGroup) -> [Int: Set<Int>] {
		let width = Int(model.exportWidth) ?? model.projectFormat?.width ?? 1920
		let height = Int(model.exportHeight) ?? model.projectFormat?.height ?? 1080
		let language = AudioSetupSettings.shared.selectedLanguage
		var result: [Int: Set<Int>] = [:]
		for row in group.sentences {
			result[row.id] = CaptionBuilder.predictedBreakIndices(
				row: row,
				style: model.captionStyle,
				textStyle: model.textStyle,
				exportWidth: width,
				exportHeight: height,
				language: language
			)
		}
		return result
	}
}
