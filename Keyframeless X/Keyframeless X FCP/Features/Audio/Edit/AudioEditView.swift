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
		.onReceive(NotificationCenter.default.publisher(for: .aiTransformApplied)) { _ in
			rebuildRows()
		}
		.onAppear {
			if model.editSelectedClips == nil {
				model.editSelectedClips = defaultEditSelection
			}
			rows = AudioEditRowBuilder.buildRows(
				clips: model.audioClips, format: model.projectFormat, projectKey: model.projectKey)
			updateSRTOverlaps()
			// On non-text-field clicks, redirect first responder to the timeline's
			// AxisDocumentView so spacebar can stop playback. Must happen during a
			// real mouseDown - see TimelineFirstResponder comment for details.
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
		.onReceive(model.objectWillChange) { _ in
			DispatchQueue.main.async {
				updateSRTOverlaps()
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
				allowedIndices: transcribedIndices,
				showOverlapsLegend: !srtOverlapRegions.isEmpty
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
			TimelineFooterMessages(clips: model.audioClips)
				.padding(.top, KKSpacingMD)
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
						Button {
							importSRTProjectWide()
						} label: {
							Label("Import SRT", systemImage: "square.and.arrow.down")
								.font(.system(size: 11))
						}
						.buttonStyle(.plain)
						.foregroundStyle(Color.kkWarning)
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
								let breaksByRow = predictedBreaksByRow
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
									ForEach(flatTranscribedRows) { item in
										flatRowView(item, breaksByRow: breaksByRow)
									}
								}
								.padding(KKPaddingMD)
								Color.clear
									.frame(height: 0)
									.onChange(of: editingRowID) {
										guard let id = editingRowID else { return }
										withAnimation {
											proxy.scrollTo(id, anchor: .center)
										}
									}
							}
						}
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
										hoveredClipIndex: $hoveredClipIndex,
										onTranscribe: {
											model.selectedClips = [row.clipIndex]
											model.stage = .setup
										},
										onImportSRT: { importSRT(for: row.clipIndex) }
									)
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

	private var flatTranscribedRows: [TranscribedFlatRow] {
		var result: [TranscribedFlatRow] = []
		for group in transcribedClipGroups {
			result.append(TranscribedFlatRow(group: group, kind: .header))
			for sentence in group.sentences {
				result.append(TranscribedFlatRow(group: group, kind: .sentence(sentence)))
			}
		}
		return result
	}

	private var predictedBreaksByRow: [Int: Set<Int>] {
		var result: [Int: Set<Int>] = [:]
		for group in transcribedClipGroups {
			let groupBreaks = predictedBreaksForGroup(group)
			result.merge(groupBreaks) { $1 }
		}
		return result
	}

	@ViewBuilder
	private func flatRowView(_ item: TranscribedFlatRow, breaksByRow: [Int: Set<Int>]) -> some View
	{
		switch item.kind {
		case .header:
			let isProjectWide = item.group.clipIndex == AudioModel.projectWideClipIndex
			TranscribedClipHeader(
				clipName: item.group.clipName,
				clipIndex: item.group.clipIndex,
				isCompound: item.group.isCompound,
				containsProfanity: groupContainsProfanity(item.group),
				isFromSRT: item.group.sentences.first?.isFromSRT ?? false,
				isProjectWide: isProjectWide,
				onDeleteSRT: {
					if isProjectWide {
						deleteProjectWideSRT()
					} else {
						deleteSRT(for: item.group.clipIndex)
					}
				},
				onImportSRT: {
					if isProjectWide {
						importSRTProjectWide()
					} else {
						importSRT(for: item.group.clipIndex)
					}
				},
				onImportSRTFromURL: isProjectWide
					? nil : { importSRT(from: $0, for: item.group.clipIndex) },
				selectedClips: editSelectedClips
			)
			.padding(.top, KKPaddingMD)
			.padding(.bottom, KKPaddingXS)
		case .sentence(let row):
			sentenceRowView(row: row, predictedBreaks: breaksByRow[row.id] ?? [])
		}
	}

	@ViewBuilder
	private func sentenceRowView(row: AudioEditRow, predictedBreaks: Set<Int>) -> some View {
		if let storageClip = storageClipFor(row) {
			let (playClip, playFrom, playTo) = playbackContextFor(row, storageClip: storageClip)
			SentenceRow(
				row: row,
				clip: storageClip,
				player: player,
				editingRowID: $editingRowID,
				sentenceRowIDs: sentenceRowIDs,
				captionBreaks: Set(row.captionBreaks),
				predictedBreaks: predictedBreaks,
				onToggleBreak: { wordIndex in
					guard wordIndex > 0 else { return }
					TranscriptionStore.shared.toggleCaptionBreak(
						at: wordIndex, for: storageClip,
						sentenceStart: Float(row.sentenceStart))
					let updated =
						TranscriptionStore.shared.captionBreakIndices(
							for: storageClip, sentenceStart: Float(row.sentenceStart)) ?? []
					handleBreakToggle(rowID: row.id, breaks: updated)
				},
				onEdit: { newText in
					let store = TranscriptionStore.shared
					let editedWords: [TranscriptionStore.StoredWord]?
					if newText == row.text {
						editedWords = nil
						store.setEditedWords(
							nil, for: storageClip, sentenceStart: Float(row.sentenceStart))
					} else {
						editedWords = TranscriptionStore.alignWords(
							original: row.words, editedText: newText)
						store.setEditedWords(
							editedWords, for: storageClip, sentenceStart: Float(row.sentenceStart))
					}
					handleSentenceEdit(rowID: row.id, editedWords: editedWords)
				},
				onBreaksEdited: { newBreaks in
					TranscriptionStore.shared.setCaptionBreakIndices(
						newBreaks.isEmpty ? nil : newBreaks,
						for: storageClip, sentenceStart: Float(row.sentenceStart))
					handleBreakToggle(rowID: row.id, breaks: newBreaks)
				},
				onReset: row.editedWords != nil
					? {
						TranscriptionStore.shared.setEditedWords(
							nil, for: storageClip, sentenceStart: Float(row.sentenceStart))
						handleSentenceEdit(rowID: row.id, editedWords: nil)
					} : nil,
				showTrailingBreak: false,
				playClipOverride: playClip,
				playFromOverride: playFrom,
				playToOverride: playTo
			)
			.id(row.id)
		}
	}

	private func storageClipFor(_ row: AudioEditRow) -> FCPXMLParser.AudioClip? {
		if row.isProjectWide {
			return TranscriptionStore.syntheticProjectWideClip(projectKey: model.projectKey)
		}
		guard model.audioClips.indices.contains(row.clipIndex) else { return nil }
		return model.audioClips[row.clipIndex]
	}

	private func playbackContextFor(
		_ row: AudioEditRow, storageClip: FCPXMLParser.AudioClip
	) -> (FCPXMLParser.AudioClip?, Double?, Double?) {
		guard row.isProjectWide else { return (nil, nil, nil) }
		for clip in model.audioClips
		where clip.start <= row.sentenceStart && row.sentenceStart < clip.end {
			let offset = clip.sourceStart - clip.start
			return (clip, row.sentenceStart + offset, row.sentenceEnd + offset)
		}
		return (nil, nil, nil)
	}

	private func handleSentenceEdit(rowID: Int, editedWords: [TranscriptionStore.StoredWord]?) {
		if let idx = rows.firstIndex(where: { $0.id == rowID }) {
			rows[idx].editedWords = editedWords
		}
	}

	private func handleBreakToggle(rowID: Int, breaks: [Int]) {
		if let idx = rows.firstIndex(where: { $0.id == rowID }) {
			rows[idx].captionBreaks = breaks
		}
		updateSRTOverlaps()
	}

	private func groupContainsProfanity(_ group: TranscribedClipGroup) -> Bool {
		let language = AudioSetupSettings.shared.selectedLanguage
		return group.sentences.contains { row in
			let words = row.editedWords ?? row.words
			return words.contains {
				ProfanityFilter.isProfane(
					$0.word.trimmingCharacters(in: .whitespaces), language: language)
			}
		}
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

	private func deleteSRT(for clipIndex: Int) {
		SRTImporter.deletePerClip(model: model, clipIndex: clipIndex)
		rebuildRows()
	}

	private func importSRTProjectWide() {
		guard let cues = SRTImporter.pickAndParse() else { return }
		SRTImporter.importProjectWide(into: model, cues: cues)
		rebuildRows()
	}

	private func deleteProjectWideSRT() {
		SRTImporter.deleteProjectWide(model: model)
		rebuildRows()
	}

	private func importSRT(for clipIndex: Int) {
		guard let cues = SRTImporter.pickAndParse() else { return }
		SRTImporter.importPerClip(into: model, clipIndex: clipIndex, cues: cues)
		rebuildRows()
	}

	private func importSRT(from url: URL, for clipIndex: Int) {
		guard let cues = SRTImporter.parse(from: url) else { return }
		SRTImporter.importPerClip(into: model, clipIndex: clipIndex, cues: cues)
		rebuildRows()
	}

	private func rebuildRows() {
		rows = AudioEditRowBuilder.buildRows(
			clips: model.audioClips, format: model.projectFormat, projectKey: model.projectKey)
		updateSRTOverlaps()
	}

	private var sentenceRowIDs: [Int] {
		rows.filter { !$0.isHeader && $0.isTranscribed }.map(\.id)
	}

	private var transcribedIndices: Set<Int> {
		let store = TranscriptionStore.shared
		var result = Set<Int>()
		for i in model.audioClips.indices {
			if store.isTranscribed(model.audioClips[i]) {
				result.insert(i)
			}
		}
		return result
	}

	private var defaultEditSelection: Set<Int> {
		var result = transcribedIndices
		if TranscriptionStore.shared.projectWideSrtCues(projectKey: model.projectKey) != nil {
			result.insert(AudioModel.projectWideClipIndex)
		}
		return result
	}

	private func predictedBreaksForGroup(_ group: TranscribedClipGroup) -> [Int: Set<Int>] {
		let width = Int(model.exportWidth) ?? model.projectFormat?.width ?? 1920
		let height = Int(model.exportHeight) ?? model.projectFormat?.height ?? 1080
		let language = AudioSetupSettings.shared.selectedLanguage
		let cea608 =
			model.captionImportType == .caption && model.captionFormat == .cea608
		var result: [Int: Set<Int>] = [:]
		for row in group.sentences {
			let base = CaptionBuilder.predictedBreakIndices(
				row: row,
				style: model.captionStyle,
				textStyle: model.textStyle,
				exportWidth: width,
				exportHeight: height,
				language: language
			)
			if cea608 {
				// CEA-608 export splits each segment to a 32-column row; add those breaks on top of
				// the manual/auto segment boundaries so the preview matches the export.
				result[row.id] = CaptionBuilder.cea608BreakIndices(
					row: row, baseBreaks: base, maxChars: 32)
			} else {
				result[row.id] = base
			}
		}
		return result
	}
}
