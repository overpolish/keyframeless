/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import Foundation
import UniformTypeIdentifiers

enum SRTImporter {

	static func pickAndParse() -> [SRTCue]? {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "srt")].compactMap { $0 }
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		guard panel.runModal() == .OK, let url = panel.url else { return nil }
		return parse(from: url)
	}

	static func parse(from url: URL) -> [SRTCue]? {
		guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		let cues = SRTParser.parse(raw)
		return cues.isEmpty ? nil : cues
	}

	@discardableResult
	static func importPerClip(
		into model: AudioModel, clipIndex: Int, cues: [SRTCue]
	) -> Bool {
		guard model.audioClips.indices.contains(clipIndex) else { return false }
		TranscriptionStore.shared.storeSrtCues(cues, for: model.audioClips[clipIndex])
		model.srtImportVersion &+= 1
		return true
	}

	static func importProjectWide(into model: AudioModel, cues: [SRTCue]) {
		TranscriptionStore.shared.storeProjectWideSrtCues(cues, projectKey: model.projectKey)
		var sel = model.editSelectedClips ?? []
		sel.insert(AudioModel.projectWideClipIndex)
		model.editSelectedClips = sel
		model.srtImportVersion &+= 1
	}

	static func deletePerClip(model: AudioModel, clipIndex: Int) {
		guard model.audioClips.indices.contains(clipIndex) else { return }
		TranscriptionStore.shared.removeSrtCues(for: model.audioClips[clipIndex])
		model.srtImportVersion &+= 1
	}

	static func deleteProjectWide(model: AudioModel) {
		TranscriptionStore.shared.removeProjectWideSrtCues(projectKey: model.projectKey)
		model.srtImportVersion &+= 1
	}
}
