/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AudioModel {

	func buildNativePasteboardData(from rows: [AudioEditRow]) -> Data? {
		let segments = buildCaptionSegments(from: rows)

		if captionImportType == .caption {
			// Native captions are single-line (multi-line text breaks CEA-608's character grid),
			// so collapse the segment's line breaks into one line. CEA-608 additionally caps a row
			// at 32 columns, so split long segments to fit.
			let capSegments: [CaptionSegment]
			if captionFormat == .cea608 {
				let split = CaptionBuilder.splitToMaxChars(segments, maxChars: 32)
				let timed = CEA608TimingValidator.adjusted(
					split, frameDuration: exportFramerate.rawValue)
				// Trim same-clip overlaps the validator's asymmetric pushes may have re-introduced.
				// Trim, not push, so start times stay anchored to speech timing; cross-clip overlaps
				// (e.g. simultaneous speakers across two audio clips) are preserved.
				capSegments = CaptionBuilder.enforceSequentialPerClip(timed)
			} else {
				capSegments = CaptionBuilder.enforceSequentialPerClip(segments)
			}
			let entries = capSegments.map {
				FCPCaptionPasteboardBuilder.Entry(
					text: $0.lines.joined(separator: " "),
					startTime: $0.startTime, duration: $0.endTime - $0.startTime)
			}
			return FCPCaptionPasteboardBuilder.build(
				captions: entries, format: captionFormat, frameDuration: exportFramerate.rawValue)
		}

		func makeTitleEntry(_ segment: CaptionSegment) -> FCPNativePasteboardBuilder.TitleEntry {
			FCPNativePasteboardBuilder.TitleEntry(
				displayName: segment.lines.first ?? "",
				text: segment.text,
				startTime: segment.startTime,
				duration: segment.endTime - segment.startTime,
				wordStarts: segment.wordStarts
			)
		}

		let hasOverlaps = CaptionBuilder.hasOverlaps(segments)
		let storylines: [[FCPNativePasteboardBuilder.TitleEntry]]
		let clipStarts: [Double]?
		if hasOverlaps {
			let grouped = Dictionary(grouping: segments, by: { $0.clipIndex })
			let sortedClipIndices = grouped.keys.sorted()
			storylines = sortedClipIndices.map { clipIdx in
				grouped[clipIdx]!.map(makeTitleEntry)
			}
			clipStarts = sortedClipIndices.map { audioClips[$0].start }
		} else {
			storylines = [segments.map(makeTitleEntry)]
			clipStarts = nil
		}
		let font = FCPXMLBuilder.fontInfo(postScriptName: textStyle.textFont)
		let style = FCPNativePasteboardBuilder.Style(
			fontFamily: font.familyName,
			fontPostScript: textStyle.textFont,
			fontSize: max(10, Int(textStyle.textSize)),
			colorR: textStyle.textColorR,
			colorG: textStyle.textColorG,
			colorB: textStyle.textColorB,
			colorA: textStyle.textColorA,
			yPositionPercent: textStyle.textYPosition
		)

		let templateInfo: FCPNativePasteboardBuilder.TemplateInfo?
		let publishedParams: [FCPNativePasteboardBuilder.EffectValueEntry]
		if selectedTemplate.isBuiltIn {
			templateInfo = nil
			publishedParams = []
		} else {
			let motiPath = selectedTemplate.uid
			let fileURL: String
			if motiPath.hasPrefix("~/") {
				let relative = String(motiPath.dropFirst(2))
				let base = FileManager.default.homeDirectoryForCurrentUser
					.appendingPathComponent("Movies/Motion Templates.localized")
					.appendingPathComponent(relative)
				fileURL = base.absoluteString
			} else {
				fileURL = URL(fileURLWithPath: motiPath).absoluteString
			}
			let store = TemplatePublishedParamsStore.shared
			let storedSettings = store.params(for: selectedTemplate.id)
			templateInfo = FCPNativePasteboardBuilder.TemplateInfo(
				effectID: motiPath,
				fileURL: fileURL,
				name: selectedTemplate.name,
				wordsInKeyPath: selectedTemplate.wordsInKeyPath,
				wordsInParamName: selectedTemplate.wordsInParamName,
				perWordStartsAtZero: storedSettings?.perWordStartsAtZero ?? false,
				textOzmlKey: storedSettings?.textOzmlKey,
				textOzml: storedSettings?.textOzml,
				textOzmlDefaultText: storedSettings?.textOzmlDefaultText,
				textOzmlStyleID: storedSettings?.textOzmlStyleID
			)
			publishedParams = buildNativePublishedParams()
		}

		return FCPNativePasteboardBuilder.build(
			storylines: storylines,
			clipStartTimes: clipStarts,
			style: style,
			frameDuration: exportFramerate.rawValue,
			templateInfo: templateInfo,
			publishedParams: publishedParams
		)
	}

	private func buildNativePublishedParams() -> [FCPNativePasteboardBuilder.EffectValueEntry] {
		let store = TemplatePublishedParamsStore.shared
		guard let settings = store.params(for: selectedTemplate.id) else { return [] }
		var entries: [FCPNativePasteboardBuilder.EffectValueEntry] = []
		for param in settings.allParams {
			let val = store.value(paramID: param.id, for: selectedTemplate.id)
			let key = param.effectValueKey
			switch param.kind {
			case .color:
				entries.append(
					contentsOf: OzmlBuilder.colorEntries(
						keyBase: key, r: val.r, g: val.g, b: val.b))
			case .slider:
				entries.append(
					.init(
						key: key,
						data: OzmlBuilder.slider(
							name: param.name, paramID: param.channelParamID,
							value: val.sliderValue)))
			case .toggle:
				entries.append(
					.init(
						key: key,
						data: OzmlBuilder.toggle(
							name: param.name, paramID: param.channelParamID,
							value: val.toggleValue)))
			default:
				if let defaultFont = param.defaultFont {
					let fontToUse =
						(param.kind == .font && val.customFont != nil)
						? val.customFont! : textStyle.textFont
					entries.append(
						.init(
							key: key,
							data: OzmlBuilder.font(
								name: param.name, paramID: param.channelParamID,
								font: fontToUse, defaultFont: defaultFont)))
				}
			}
		}
		return entries
	}

	func buildPublishedParamEntries() -> [FCPXMLBuilder.PublishedParamEntry] {
		let store = TemplatePublishedParamsStore.shared
		guard let settings = store.params(for: selectedTemplate.id) else { return [] }
		var entries: [FCPXMLBuilder.PublishedParamEntry] = []
		for param in settings.allParams where param.isToggleable {
			let val = store.value(paramID: param.id, for: selectedTemplate.id)
			if param.isFont { continue }
			let key = param.effectValueKey
			let valueStr: String
			switch param.kind {
			case .color:
				valueStr = "\(val.r) \(val.g) \(val.b) \(val.a)"
			case .slider:
				valueStr = "\(val.sliderValue)"
			case .toggle:
				valueStr = val.toggleValue ? "1" : "0"
			default:
				continue
			}
			entries.append(
				FCPXMLBuilder.PublishedParamEntry(name: param.name, key: key, value: valueStr))
		}
		return entries
	}
}
