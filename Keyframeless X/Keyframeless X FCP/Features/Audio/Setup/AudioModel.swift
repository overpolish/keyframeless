/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import Foundation

struct CaptionStyleSettings: Codable, Equatable {
	var maxWordsPerLine: Double = 5
	var captionLines: AudioModel.CaptionLineCount = .two
	var allCaps: Bool = false
	var censorProfanity: Bool = true
	var stripPunctuation: Bool = true
	var keepQuestionMarks: Bool = true
}

class CaptionStyleDefaults {
	static let shared = CaptionStyleDefaults()
	private(set) var settings = CaptionStyleSettings()

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/caption_style_defaults.json")
	}

	private init() { load() }

	func save(_ settings: CaptionStyleSettings) {
		self.settings = settings
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(settings).write(to: url, options: .atomic)
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let saved = try? JSONDecoder().decode(CaptionStyleSettings.self, from: data)
		else { return }
		settings = saved
	}
}

struct TextStyleSettings: Codable, Equatable {
	var textWidthPercent: Double = 80
	var textSize: Double = 100
	var textYPosition: Double = 20
	var textFont: String = "HelveticaNeue"
}

class TextStyleDefaults {
	static let shared = TextStyleDefaults()
	private(set) var settings = TextStyleSettings()

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/text_style_defaults.json")
	}

	private init() { load() }

	func save(_ settings: TextStyleSettings) {
		self.settings = settings
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(settings).write(to: url, options: .atomic)
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let saved = try? JSONDecoder().decode(TextStyleSettings.self, from: data)
		else { return }
		settings = saved
	}
}

class AudioModel: ObservableObject {

	enum Stage { case setup, edit }

	@Published var stage: Stage = .setup
	@Published var isDraggingToFCP: Bool = false
	@Published var projectFormat: FCPXMLParser.ProjectFormat?
	@Published var audioClips: [FCPXMLParser.AudioClip] = []
	@Published var selectedClips: Set<Int> = []
	@Published var editSelectedClips: Set<Int>?
	@Published var dropItems: [FCPXMLParser.DropItem] = []
	@Published var useTimecode: Bool = true
	@Published var exportWidth: String = ""
	@Published var exportHeight: String = ""
	@Published var exportFramerate: Framerate = .fps30
	@Published var exportSettingsInitialized: Bool = false
	@Published var textWidthPercent: Double = TextStyleDefaults.shared.settings.textWidthPercent
	@Published var textSize: Double = TextStyleDefaults.shared.settings.textSize
	@Published var textYPosition: Double = TextStyleDefaults.shared.settings.textYPosition
	@Published var textFont: String = TextStyleDefaults.shared.settings.textFont

	@Published var maxWordsPerLine: Double = CaptionStyleDefaults.shared.settings.maxWordsPerLine
	@Published var captionLines: CaptionLineCount = CaptionStyleDefaults.shared.settings
		.captionLines
	@Published var allCaps: Bool = CaptionStyleDefaults.shared.settings.allCaps
	@Published var censorProfanity: Bool = CaptionStyleDefaults.shared.settings.censorProfanity
	@Published var stripPunctuation: Bool = CaptionStyleDefaults.shared.settings.stripPunctuation
	@Published var keepQuestionMarks: Bool = CaptionStyleDefaults.shared.settings.keepQuestionMarks

	enum CaptionLineCount: String, Codable {
		case one, two
	}

	var textStyle: TextStyleSettings {
		get {
			TextStyleSettings(
				textWidthPercent: textWidthPercent, textSize: textSize,
				textYPosition: textYPosition, textFont: textFont)
		}
		set {
			textWidthPercent = newValue.textWidthPercent
			textSize = newValue.textSize
			textYPosition = newValue.textYPosition
			textFont = newValue.textFont
		}
	}

	var captionStyle: CaptionStyleSettings {
		get {
			CaptionStyleSettings(
				maxWordsPerLine: maxWordsPerLine, captionLines: captionLines,
				allCaps: allCaps, censorProfanity: censorProfanity,
				stripPunctuation: stripPunctuation, keepQuestionMarks: keepQuestionMarks)
		}
		set {
			maxWordsPerLine = newValue.maxWordsPerLine
			captionLines = newValue.captionLines
			allCaps = newValue.allCaps
			censorProfanity = newValue.censorProfanity
			stripPunctuation = newValue.stripPunctuation
			keepQuestionMarks = newValue.keepQuestionMarks
		}
	}

	private var cancellables = Set<AnyCancellable>()

	init() {
		load()
		objectWillChange
			.debounce(for: .milliseconds(500), scheduler: RunLoop.main)
			.sink { [weak self] _ in self?.save() }
			.store(in: &cancellables)
	}

	func buildCaptionSegments(from rows: [AudioEditRow]) -> [CaptionSegment] {
		let selected = editSelectedClips ?? Set(audioClips.indices)
		let filtered = rows.filter { $0.isHeader || selected.contains($0.clipIndex) }
		return CaptionBuilder.build(
			rows: filtered,
			clips: audioClips,
			style: captionStyle,
			textStyle: textStyle,
			exportWidth: Int(exportWidth) ?? projectFormat?.width ?? 1920,
			language: AudioSetupSettings.shared.selectedLanguage
		)
	}

	func buildFCPXML(from rows: [AudioEditRow]) -> String {
		let segments = buildCaptionSegments(from: rows)
		let format = FCPXMLBuilder.ExportFormat(
			width: Int(exportWidth) ?? projectFormat?.width ?? 1920,
			height: Int(exportHeight) ?? projectFormat?.height ?? 1080,
			frameDuration: exportFramerate.rawValue
		)
		return FCPXMLBuilder.build(
			segments: segments,
			textStyle: textStyle,
			format: format
		)
	}

	func insertTitle(rows: [AudioEditRow]) {
		let fcpxml = buildFCPXML(from: rows)
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("keyframeless_captions.fcpxml")
		try? fcpxml.write(to: tmpURL, atomically: true, encoding: .utf8)
		NSWorkspace.shared.open(tmpURL)
	}

	private struct PersistedState: Codable {
		var fcpProcessID: Int32
		var projectFormat: FCPXMLParser.ProjectFormat?
		var audioClips: [FCPXMLParser.AudioClip]
		var selectedClips: [Int]
		var editSelectedClips: [Int]?
		var dropItems: [FCPXMLParser.DropItem]
		var useTimecode: Bool
		var exportWidth: String?
		var exportHeight: String?
		var exportFramerate: Framerate?
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
		editSelectedClips = state.editSelectedClips.map(Set.init)
		dropItems = state.dropItems
		useTimecode = state.useTimecode
		if let w = state.exportWidth { exportWidth = w }
		if let h = state.exportHeight { exportHeight = h }
		if let fr = state.exportFramerate { exportFramerate = fr }
		if state.exportWidth != nil { exportSettingsInitialized = true }
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
			editSelectedClips: editSelectedClips.map(Array.init),
			dropItems: dropItems,
			useTimecode: useTimecode,
			exportWidth: exportWidth.isEmpty ? nil : exportWidth,
			exportHeight: exportHeight.isEmpty ? nil : exportHeight,
			exportFramerate: exportFramerate
		)
		try? JSONEncoder().encode(state).write(to: url, options: .atomic)
	}

}
