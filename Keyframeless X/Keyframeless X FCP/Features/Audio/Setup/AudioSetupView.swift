/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct AudioSetupView: View {
	@ObservedObject var model: AudioModel
	@ObservedObject var audioModelManager: AudioModelManager
	var isProcessing: Bool
	var onProcess: (_ replaceAll: Bool) -> Void
	@StateObject private var audioPlayer = AudioPlayer()
	@State private var dropState: DropState = .idle
	@State private var isTargeted = false
	@State private var timelineLoadID = UUID()
	enum DropState { case idle, denied, dropped }

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			topRow
			SetupTimelineArea(
				model: model,
				audioPlayer: audioPlayer,
				dropState: dropState,
				isTargeted: isTargeted,
				timelineLoadID: timelineLoadID,
				onDrop: handleDrop,
				onDenied: handleDenied,
				onTargeted: { isTargeted = $0 }
			)
			.frame(maxHeight: .infinity)
			.layoutPriority(1)
			HStack(alignment: .top, spacing: KKSpacingLG) {
				AudioModelPickerView(manager: audioModelManager)
					.frame(maxHeight: .infinity)
				AudioLanguagePickerView(manager: audioModelManager)
					.frame(maxHeight: .infinity)
				AudioTermsView(manager: audioModelManager)
					.frame(maxHeight: .infinity)
			}
			.frame(maxHeight: .infinity)
			HStack(spacing: KKSpacingMD) {
				ProcessButton(
					disabled: processDisabled,
					action: { onProcess(true) }
				)
				ProcessSelectedButton(
					disabled: processDisabled,
					action: { onProcess(false) }
				)
				Button {
					importSRTProjectWide()
				} label: {
					Label("Import SRT", systemImage: "square.and.arrow.down")
						.font(.system(size: 11))
						.padding(.horizontal, KKPaddingLG)
						.padding(.vertical, KKSpacingSM)
						.contentShape(Capsule())
				}
				.buttonStyle(.plain)
				.foregroundStyle(Color.kkWarning)
				.disabled(model.audioClips.isEmpty)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onDisappear { audioPlayer.stop() }
	}

	private func importSRTProjectWide() {
		guard let cues = SRTImporter.pickAndParse() else { return }
		SRTImporter.importProjectWide(into: model, cues: cues)
		model.stage = .edit
	}

	private var processDisabled: Bool {
		isProcessing
			|| !model.selectedClips.isDisjoint(with: model.loadingWaveformIndices)
			|| model.selectedClips.isEmpty
			|| audioModelManager.selectedModel == nil
			|| audioModelManager.downloadingModel != nil
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

	private func handleDrop(_ doc: XMLDocument) {
		let clips = FCPXMLParser.audioClips(in: doc)
		model.audioClips = clips
		model.allAudioClips = FCPXMLParser.audioClips(in: doc, dialogueOnly: false)
		model.selectedClips = []
		model.editSelectedClips = nil
		model.dropItems = FCPXMLParser.topLevelItems(in: doc)
		let fmt = FCPXMLParser.projectFormat(in: doc) ?? .default
		model.projectFormat = fmt
		model.exportWidth = "\(fmt.width)"
		model.exportHeight = "\(fmt.height)"
		model.exportFramerate = Framerate.from(frameDuration: fmt.frameDuration)
		model.exportSettingsInitialized = true
		model.useTimecode = !fmt.fpsDisplay.isEmpty
		dropState = .dropped
		isTargeted = false
		timelineLoadID = UUID()
	}

	private func handleDenied() {
		dropState = .denied
		model.audioClips = []
		model.selectedClips = []
		model.editSelectedClips = nil
		isTargeted = false
	}
}
