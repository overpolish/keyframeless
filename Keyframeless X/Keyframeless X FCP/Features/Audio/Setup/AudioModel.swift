/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

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
	@Published var textColorR: Double = TextStyleDefaults.shared.settings.textColorR
	@Published var textColorG: Double = TextStyleDefaults.shared.settings.textColorG
	@Published var textColorB: Double = TextStyleDefaults.shared.settings.textColorB
	@Published var textColorA: Double = TextStyleDefaults.shared.settings.textColorA

	@Published var maxWordsPerLine: Double = CaptionStyleDefaults.shared.settings.maxWordsPerLine
	@Published var captionLines: CaptionLineCount = CaptionStyleDefaults.shared.settings
		.captionLines
	@Published var allCaps: Bool = CaptionStyleDefaults.shared.settings.allCaps
	@Published var censorProfanity: Bool = CaptionStyleDefaults.shared.settings.censorProfanity
	@Published var stripPunctuation: Bool = CaptionStyleDefaults.shared.settings.stripPunctuation
	@Published var keepQuestionMarks: Bool = CaptionStyleDefaults.shared.settings.keepQuestionMarks
	@Published var noGaps: Bool = CaptionStyleDefaults.shared.settings.noGaps

	@Published var captionImportType: CaptionImportType = .title
	@Published var captionFormat: CaptionFormat = .itt

	@Published var captionTemplates: [CaptionTemplate] = []
	@Published var selectedTemplate: CaptionTemplate = .basicTitle
	@Published var paramsModalTemplate: CaptionTemplate?
	@Published var paramsModalParams: [PublishedParameter] = []
	@Published var paramsModalHasPerWord: Bool = false
	@Published var publishModalTemplate: CaptionTemplate?
	@Published var updateModalTemplate: (CaptionTemplate, CommunityTemplate)?

	var textStyle: TextStyleSettings {
		get {
			TextStyleSettings(
				textWidthPercent: textWidthPercent, textSize: textSize,
				textYPosition: textYPosition, textFont: textFont,
				textColorR: textColorR, textColorG: textColorG,
				textColorB: textColorB, textColorA: textColorA)
		}
		set {
			textWidthPercent = newValue.textWidthPercent
			textSize = newValue.textSize
			textYPosition = newValue.textYPosition
			textFont = newValue.textFont
			textColorR = newValue.textColorR
			textColorG = newValue.textColorG
			textColorB = newValue.textColorB
			textColorA = newValue.textColorA
		}
	}

	var captionStyle: CaptionStyleSettings {
		get {
			CaptionStyleSettings(
				maxWordsPerLine: maxWordsPerLine, captionLines: captionLines,
				allCaps: allCaps, censorProfanity: censorProfanity,
				stripPunctuation: stripPunctuation, keepQuestionMarks: keepQuestionMarks,
				noGaps: noGaps)
		}
		set {
			maxWordsPerLine = newValue.maxWordsPerLine
			captionLines = newValue.captionLines
			allCaps = newValue.allCaps
			censorProfanity = newValue.censorProfanity
			stripPunctuation = newValue.stripPunctuation
			keepQuestionMarks = newValue.keepQuestionMarks
			noGaps = newValue.noGaps
		}
	}

	private var cancellables = Set<AnyCancellable>()

	init() {
		load()
		captionTemplates = CaptionTemplateScanner.scan(
			customTemplates: CustomTemplateStore.shared.templates)
		resolveSelectedTemplate()
		objectWillChange
			.debounce(for: .milliseconds(500), scheduler: RunLoop.main)
			.sink { [weak self] _ in self?.save() }
			.store(in: &cancellables)
	}

	func refreshTemplates() {
		captionTemplates = CaptionTemplateScanner.scan(
			customTemplates: CustomTemplateStore.shared.templates)
		if !captionTemplates.contains(where: { $0.id == selectedTemplate.id }) {
			selectedTemplate = captionTemplates.first ?? .basicTitle
		}
	}

	func addCustomTemplate(from url: URL) {
		guard let template = CaptionTemplate.fromMotiFile(at: url) else { return }
		if let existing = captionTemplates.first(where: { $0.uid == template.uid }) {
			selectedTemplate = existing
			return
		}
		let store = CustomTemplateStore.shared
		store.add(template)
		refreshTemplates()
		if let added = captionTemplates.first(where: { $0.id == template.id }) {
			selectedTemplate = added
		}
	}

	func removeCustomTemplate(_ template: CaptionTemplate) {
		CustomTemplateStore.shared.remove(template)
		refreshTemplates()
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
			exportHeight: Int(exportHeight) ?? projectFormat?.height ?? 1080,
			language: AudioSetupSettings.shared.selectedLanguage
		)
	}

	func buildFCPXML(from rows: [AudioEditRow]) -> String {
		let segments = CaptionBuilder.enforceSequentialPerClip(
			buildCaptionSegments(from: rows))
		let format = FCPXMLBuilder.ExportFormat(
			width: Int(exportWidth) ?? projectFormat?.width ?? 1920,
			height: Int(exportHeight) ?? projectFormat?.height ?? 1080,
			frameDuration: exportFramerate.rawValue
		)
		let publishedParams = buildPublishedParamEntries()
		let startsAtZero =
			TemplatePublishedParamsStore.shared.params(for: selectedTemplate.id)?
			.perWordStartsAtZero ?? false

		let hasOverlaps = CaptionBuilder.hasOverlaps(segments)
		let storylines: [[CaptionSegment]]
		if hasOverlaps {
			let grouped = Dictionary(grouping: segments, by: { $0.clipIndex })
			storylines = grouped.keys.sorted().map { grouped[$0]! }
		} else {
			storylines = [segments]
		}

		return FCPXMLBuilder.build(
			storylines: storylines,
			textStyle: textStyle,
			format: format,
			template: selectedTemplate,
			publishedParams: publishedParams,
			perWordStartsAtZero: startsAtZero
		)
	}

	func srtHasOverlaps(from rows: [AudioEditRow]) -> Bool {
		CaptionBuilder.hasOverlaps(buildCaptionSegments(from: rows))
	}

	func srtOverlapRegions(from rows: [AudioEditRow]) -> [CaptionBuilder.OverlapRegion] {
		let selected = editSelectedClips ?? Set(audioClips.indices)
		let clips = audioClips.enumerated()
			.filter { selected.contains($0.offset) }
			.map { $0.element }
		let sorted = clips.sorted { $0.start < $1.start }
		var regions: [CaptionBuilder.OverlapRegion] = []
		let epsilon = 0.001
		var maxEnd = -Double.infinity
		for i in 0..<sorted.count {
			if sorted[i].start < maxEnd - epsilon {
				regions.append(
					CaptionBuilder.OverlapRegion(
						start: sorted[i].start,
						end: min(maxEnd, sorted[i].end)
					))
			}
			maxEnd = max(maxEnd, sorted[i].end)
		}
		return regions
	}

	func exportSRT(from rows: [AudioEditRow]) {
		let segments = buildCaptionSegments(from: rows)
		let srt = CaptionBuilder.formatSRT(segments)

		let projectName = dropItems.first?.name ?? "captions"
		let timestamp = ISO8601DateFormatter().string(from: Date())
			.replacingOccurrences(of: ":", with: "-")
		let defaultName = "\(projectName)_\(timestamp).srt"

		let panel = NSSavePanel()
		panel.nameFieldStringValue = defaultName
		panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		try? srt.write(to: url, atomically: true, encoding: .utf8)
	}

	func insertTitle(rows: [AudioEditRow]) {
		let fcpxml =
			captionImportType == .caption
			? buildNativeCaptionFCPXML(from: rows)
			: buildFCPXML(from: rows)
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("keyframeless_captions.fcpxml")
		try? fcpxml.write(to: tmpURL, atomically: true, encoding: .utf8)
		NSWorkspace.shared.open(tmpURL)
	}

	func buildNativeCaptionFCPXML(from rows: [AudioEditRow]) -> String {
		var segments = buildCaptionSegments(from: rows)
		if captionFormat == .cea608 {
			let maxLines = captionStyle.captionLines == .two ? 2 : 1
			segments = CaptionBuilder.splitCEA608Multiline(
				segments, maxCharsPerLine: 32, maxLines: maxLines)
			segments = CaptionBuilder.mergeOrphansCEA608(
				segments, maxCharsPerLine: 32, maxLines: maxLines,
				maxWordsPerLine: Int(captionStyle.maxWordsPerLine))
			segments = CEA608TimingValidator.adjusted(
				segments, frameDuration: exportFramerate.rawValue)
		}
		segments = CaptionBuilder.enforceSequentialPerClip(segments)
		// Mirror the pasteboard path: the CEA-608 validator pushes start times later for
		// SCC byte-pair compliance, which reopens gaps closeAllGaps closed inside
		// buildCaptionSegments. Re-close here so noGaps holds for CEA-608 too.
		if captionStyle.noGaps {
			segments = CaptionBuilder.closeAllGaps(segments)
		}
		let format = FCPXMLBuilder.ExportFormat(
			width: Int(exportWidth) ?? projectFormat?.width ?? 1920,
			height: Int(exportHeight) ?? projectFormat?.height ?? 1080,
			frameDuration: exportFramerate.rawValue
		)
		let language = AudioSetupSettings.shared.selectedLanguage ?? "en"
		return FCPXMLBuilder.buildNativeCaptions(
			segments: segments,
			format: format,
			role: captionFormat.role(language: language),
			captionFormat: captionFormat
		)
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
		var textStyle: TextStyleSettings?
		var captionStyle: CaptionStyleSettings?
		var selectedTemplateID: String?
		var captionImportType: CaptionImportType?
		var captionFormat: CaptionFormat?
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
		if let ts = state.textStyle { textStyle = ts }
		if let cs = state.captionStyle { captionStyle = cs }
		if let tid = state.selectedTemplateID { _pendingTemplateID = tid }
		if let ct = state.captionImportType { captionImportType = ct }
		if let cf = state.captionFormat { captionFormat = cf }
	}

	private var _pendingTemplateID: String?

	func resolveSelectedTemplate() {
		guard let tid = _pendingTemplateID,
			let match = captionTemplates.first(where: { $0.id == tid })
		else { return }
		selectedTemplate = match
		_pendingTemplateID = nil
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
			exportFramerate: exportFramerate,
			textStyle: textStyle,
			captionStyle: captionStyle,
			selectedTemplateID: selectedTemplate.id,
			captionImportType: captionImportType,
			captionFormat: captionFormat
		)
		try? JSONEncoder().encode(state).write(to: url, options: .atomic)
	}

}
