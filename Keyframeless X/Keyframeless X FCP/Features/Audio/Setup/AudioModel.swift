/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import Foundation

class AudioModel: ObservableObject {

	enum Stage { case setup, edit }

	@Published var stage: Stage = .setup
	@Published var projectFormat: FCPXMLParser.ProjectFormat?
	@Published var audioClips: [FCPXMLParser.AudioClip] = []
	@Published var selectedClips: Set<Int> = []
	@Published var dropItems: [FCPXMLParser.DropItem] = []
	@Published var useTimecode: Bool = true

	private var cancellables = Set<AnyCancellable>()

	init() {
		load()
		objectWillChange
			.debounce(for: .milliseconds(500), scheduler: RunLoop.main)
			.sink { [weak self] _ in self?.save() }
			.store(in: &cancellables)
	}

	func insertTitle() {
		let fcpxml = FCPXMLBuilder.titleStorylineXML(text: "hello from keyframeless x")
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("keyframeless_title.fcpxml")
		try? fcpxml.write(to: tmpURL, atomically: true, encoding: .utf8)
		NSWorkspace.shared.open(tmpURL)
	}

	private struct PersistedState: Codable {
		var fcpProcessID: Int32
		var projectFormat: FCPXMLParser.ProjectFormat?
		var audioClips: [FCPXMLParser.AudioClip]
		var selectedClips: [Int]
		var dropItems: [FCPXMLParser.DropItem]
		var useTimecode: Bool
	}

	private static var fcpProcessID: Int32? {
		NSRunningApplication
			.runningApplications(withBundleIdentifier: "com.apple.FinalCut")
			.first?.processIdentifier
	}

	private var stateFileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/audio_state.json")
	}

	private func load() {
		guard let currentPID = Self.fcpProcessID,
			let url = stateFileURL,
			let data = try? Data(contentsOf: url),
			let state = try? JSONDecoder().decode(PersistedState.self, from: data),
			state.fcpProcessID == currentPID
		else { return }
		projectFormat = state.projectFormat
		audioClips = state.audioClips
		selectedClips = Set(state.selectedClips)
		dropItems = state.dropItems
		useTimecode = state.useTimecode
	}

	private func save() {
		guard let pid = Self.fcpProcessID, let url = stateFileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let state = PersistedState(
			fcpProcessID: pid,
			projectFormat: projectFormat,
			audioClips: audioClips,
			selectedClips: Array(selectedClips),
			dropItems: dropItems,
			useTimecode: useTimecode
		)
		try? JSONEncoder().encode(state).write(to: url, options: .atomic)
	}

}
