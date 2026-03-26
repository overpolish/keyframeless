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
				ProcessSelectedButton(
					disabled: processDisabled,
					action: { onProcess(false) }
				)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onDisappear { audioPlayer.stop() }
	}

	private var processDisabled: Bool {
		model.selectedClips.isEmpty
			|| whisperManager.selectedModel == nil
			|| whisperManager.downloadingModel != nil
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
		model.selectedClips = Set(clips.indices)
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
