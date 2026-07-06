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
			var capSegments: [CaptionSegment]
			if captionFormat == .cea608 {
				let maxLines = captionStyle.captionLines == .two ? 2 : 1
				let split = CaptionBuilder.splitCEA608Multiline(
					segments, maxCharsPerLine: 32, maxLines: maxLines)
				let merged = CaptionBuilder.mergeOrphansCEA608(
					split, maxCharsPerLine: 32, maxLines: maxLines,
					maxWordsPerLine: Int(captionStyle.maxWordsPerLine))
				let timed = CEA608TimingValidator.adjusted(
					merged, frameDuration: exportFramerate.rawValue)
				// Trim same-clip overlaps the validator's asymmetric pushes may have re-introduced.
				// Trim, not push, so start times stay anchored to speech timing; cross-clip overlaps
				// (e.g. simultaneous speakers across two audio clips) are preserved.
				capSegments = CaptionBuilder.enforceSequentialPerClip(timed)
			} else {
				capSegments = CaptionBuilder.enforceSequentialPerClip(segments)
			}
			// buildCaptionSegments applies noGaps before splitting/validation; the CEA-608
			// validator then pushes start times later for SCC byte-pair compliance, which
			// reopens gaps. Re-close after the pipeline so the user-visible result honors
			// noGaps regardless of format (extending end to next start; the gap the validator
			// opened lives at next.start, not after it).
			if captionStyle.noGaps {
				capSegments = CaptionBuilder.closeAllGaps(capSegments)
			}
			// All formats use \n between rows: iTT/SRT render embedded \n in the attributed
			// string as a real line break; CEA-608's grid layout is row-by-row (cellY per row)
			// so the pasteboard builder fans \n-delimited text into one PC per row.
			let entries = capSegments.map {
				FCPCaptionPasteboardBuilder.Entry(
					text: $0.lines.joined(separator: "\n"),
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
			clipStarts = Array(repeating: 0, count: sortedClipIndices.count)
		} else {
			storylines = [segments.map(makeTitleEntry)]
			clipStarts = [0]
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
				textOzmlStyleID: storedSettings?.textOzmlStyleID,
				verticalAlignmentTag: verticalAlignmentTag()
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

	/// Selected Vertical Alignment tag for the native text-ozml patch. The param is
	/// identified by channel path (`2/373/2`), which survives a creator renaming it.
	private func verticalAlignmentTag() -> Int? {
		let store = TemplatePublishedParamsStore.shared
		guard let settings = store.params(for: selectedTemplate.id),
			let va = settings.allParams.first(where: {
				$0.kind == .dropdown && $0.channelPath == "2/373/2"
			})
		else { return nil }
		return store.value(paramID: va.id, for: selectedTemplate.id).enumValue
	}

	private func buildNativePublishedParams() -> [FCPNativePasteboardBuilder.EffectValueEntry] {
		let store = TemplatePublishedParamsStore.shared
		guard let settings = store.params(for: selectedTemplate.id) else { return [] }
		var entries: [FCPNativePasteboardBuilder.EffectValueEntry] = []
		for param in settings.allParams where !param.isTextSize {
			let val = store.value(paramID: param.id, for: selectedTemplate.id)
			let key = param.styleKey ?? param.effectValueKey
			switch param.kind {
			case .color:
				entries.append(
					contentsOf: OzmlBuilder.colorEntries(
						keyBase: key, r: val.r, g: val.g, b: val.b))
			case .slider:
				let blurCh =
					"\(PublishedParameter.TextFilter.dropShadow)/\(PublishedParameter.TextFilter.shadowBlur)"
				if param.channelPath == blurCh || param.channelPath.hasSuffix("/" + blurCh) {
					// Blur is a 2D X/Y point natively; a single value maps to both (uniform,
					// no elliptical support). Emit the LEAF channel flags (8589934608), NOT
					// param.overrideFlags — those are the Blur GROUP's flags, whose 0x1000
					// folder bit makes FCP treat each X/Y leaf as a self-referential folder
					// and crash tearing the scene down (cyclic removeAllDependencies).
					for (axis, pid) in [("X", "1"), ("Y", "2")] {
						entries.append(
							.init(
								key: "\(key)/\(pid)",
								data: OzmlBuilder.slider(
									name: axis, paramID: pid, value: val.sliderValue)))
					}
				} else {
					entries.append(
						.init(
							key: key,
							data: OzmlBuilder.slider(
								name: param.name, paramID: param.channelParamID,
								value: val.sliderValue, flags: param.overrideFlags)))
				}
			case .percent:
				// A percentage control (0-100) → the native 0-1 value.
				entries.append(
					.init(
						key: key,
						data: OzmlBuilder.slider(
							name: param.name, paramID: param.channelParamID,
							value: val.sliderValue / 100, flags: param.overrideFlags)))
			case .rotation:
				// Motion stores angles in degrees, but the native ozml value is in
				// RADIANS (sending 45 raw reads back as 45 rad = 2578°). Convert.
				entries.append(
					.init(
						key: key,
						data: OzmlBuilder.slider(
							name: param.name, paramID: param.channelParamID,
							value: val.sliderValue * .pi / 180,
							flags: param.overrideFlags)))
			case .toggle:
				if let baseFlags = param.filterEnableFlags {
					// Filter-enable (e.g. Drop Shadow): FCP enables the filter by the
					// PRESENCE of an override at the group key; omit it to leave it off.
					if val.toggleValue {
						entries.append(
							.init(
								key: key,
								data: OzmlBuilder.filterEnable(
									name: param.name, paramID: param.channelParamID,
									enabledFlags: baseFlags & ~0x8000)))
					}
				} else {
					entries.append(
						.init(
							key: key,
							data: OzmlBuilder.toggle(
								name: param.name, paramID: param.channelParamID,
								value: val.toggleValue)))
				}
			case .point:
				// A point overrides its X (child id 1) and Y (child id 2) sub-channels.
				// The field is in FCP units; the native value is field ÷ display scale.
				let s = PublishedParameter.pointDisplayScale
				entries.append(
					.init(
						key: "\(key)/1",
						data: OzmlBuilder.slider(name: "X", paramID: "1", value: val.pointX / s)))
				entries.append(
					.init(
						key: "\(key)/2",
						data: OzmlBuilder.slider(name: "Y", paramID: "2", value: val.pointY / s)))
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

		// The caption's Text Size drives the text-style font size. We patch the injected
		// scene's Size, but character-animation templates ignore that scene and render
		// the template's own size, so also emit the real style-size override — the same
		// mechanism FCP's own inspector uses (verified against a working manual edit). The
		// key/flags are synthesized from the text style, so this works whether or not the
		// template publishes "Size".
		// textSizeKey is synthesized at parse; fall back to a published Size param's own
		// key/flags so configs stored before this field existed keep working pre-reimport.
		let sizeParam = settings.allParams.first(where: { $0.isTextSize })
		if let sizeKey = settings.textSizeKey ?? sizeParam?.styleKey {
			let size = Double(max(10, Int(textStyle.textSize)))
			let flags =
				(settings.textSizeFlags ?? sizeParam?.nativeFlags).map { $0 | 0x1_0000_0000 }
				?? 8_589_934_608
			entries.append(
				.init(
					key: sizeKey,
					data: OzmlBuilder.slider(name: "Size", paramID: "3", value: size, flags: flags))
			)
		}
		return entries
	}

	/// FCPXML enables face-layer filters (drop shadow, outline, …) via `<text-style>`
	/// attributes rather than the native group-key override, so map each enabled filter
	/// toggle to its attributes. Colours are read from the template's published sub-params
	/// (their per-filter sparse base — red outline / black shadow — is baked in at parse),
	/// with a user-set Colour control taking precedence. Glow has no text-style equivalent
	/// (FCP drops it on import). shadow opacity/offset + outline width keep FCP defaults
	/// except width, which reads its published value.
	func enabledTextFilterAttrs() -> String {
		let store = TemplatePublishedParamsStore.shared
		guard let settings = store.params(for: selectedTemplate.id) else { return "" }

		typealias TF = PublishedParameter.TextFilter

		// "R G B" for a filter's Colour sub-param at `group/sub`: a user-set control wins,
		// else the parsed template default (per-filter base already baked in at parse), else
		// `base` when the filter publishes no colour at all.
		func filterColorRGB(group: String, sub: String, base: String) -> String {
			guard
				let col = settings.allParams.first(where: { $0.channelPath == group + "/" + sub })
			else { return base }
			if col.kind == .color,
				let custom = store.sessionValue(paramID: col.id, for: selectedTemplate.id)
			{
				return "\(custom.r) \(custom.g) \(custom.b)"
			}
			return "\(col.defaultR ?? 0) \(col.defaultG ?? 0) \(col.defaultB ?? 0)"
		}

		// A filter's numeric sub-param at `group/sub`: the control's live value if it's a
		// slider/percent the user set, else the parsed template default, else `fallback`.
		func filterNumber(group: String, sub: String, fallback: Double) -> Double {
			guard let p = settings.allParams.first(where: { $0.channelPath == group + "/" + sub })
			else { return fallback }
			if p.kind == .slider || p.kind == .rotation || p.kind == .percent {
				return store.value(paramID: p.id, for: selectedTemplate.id).sliderValue
			}
			return p.defaultNumber ?? fallback
		}

		var attrs = ""
		for param in settings.allParams where param.filterEnableFlags != nil {
			guard store.value(paramID: param.id, for: selectedTemplate.id).toggleValue else {
				continue
			}
			// Detect by FIXED Motion channel id (rename-proof), not the published name.
			let group = param.channelPath
			switch param.channelParamID {
			case TF.dropShadow:
				let rgb = filterColorRGB(group: group, sub: TF.shadowColor, base: "0 0 0")
				// Opacity is a 0-100 percentage → FCP's 0-1 alpha; distance/angle map 1:1.
				let alpha = filterNumber(group: group, sub: TF.shadowOpacity, fallback: 75) / 100
				let distance = filterNumber(group: group, sub: TF.shadowDistance, fallback: 5)
				let angle = filterNumber(group: group, sub: TF.shadowAngle, fallback: 315)
				attrs +=
					" shadowColor=\"\(rgb) \(alpha)\" shadowOffset=\"\(distance) \(angle)\""
				// Blur is a uniform single value (its X=Y); emit only when set. FCP renders
				// shadowBlurRadius at half the value we pass (25 → 12.5), so double it to
				// match the native drag.
				let blur = filterNumber(group: group, sub: TF.shadowBlur, fallback: 0)
				if blur > 0 { attrs += " shadowBlurRadius=\"\(blur * 2)\"" }
			case TF.outline:
				let rgb = filterColorRGB(group: group, sub: TF.outlineColor, base: "1 0 0")
				let width = filterNumber(group: group, sub: TF.outlineWidth, fallback: 13)
				attrs += " strokeColor=\"\(rgb) 1\" strokeWidth=\"\(-width)\""
			default:
				break  // glow etc — no text-style equivalent
			}
		}
		return attrs
	}

	func buildPublishedParamEntries() -> [FCPXMLBuilder.PublishedParamEntry] {
		let store = TemplatePublishedParamsStore.shared
		guard let settings = store.params(for: selectedTemplate.id) else { return [] }
		var entries: [FCPXMLBuilder.PublishedParamEntry] = []
		for param in settings.allParams where param.isToggleable && !param.isTextSize {
			let val = store.value(paramID: param.id, for: selectedTemplate.id)
			if param.isFont { continue }
			// Filter-enable toggles map to text-style shadow attrs in FCPXML (a
			// different mechanism than the native group-key override); skip for now.
			if param.filterEnableFlags != nil { continue }
			let key = param.styleKey ?? param.effectValueKey
			if param.kind == .point {
				entries.append(
					.init(name: "\(param.name) X", key: "\(key)/1", value: "\(val.pointX)"))
				entries.append(
					.init(name: "\(param.name) Y", key: "\(key)/2", value: "\(val.pointY)"))
				continue
			}
			let valueStr: String
			switch param.kind {
			case .color:
				valueStr = "\(val.r) \(val.g) \(val.b) \(val.a)"
			case .slider, .rotation:
				valueStr = "\(val.sliderValue)"
			case .percent:
				// Percentage control (0-100) → FCP's 0-1 value.
				valueStr = "\(val.sliderValue / 100)"
			case .toggle:
				valueStr = val.toggleValue ? "1" : "0"
			case .dropdown:
				valueStr = "\(val.enumValue)"
			default:
				continue
			}
			entries.append(
				FCPXMLBuilder.PublishedParamEntry(name: param.name, key: key, value: valueStr))
		}

		// Mirror the native path: the caption's Text Size drives the text-style font size
		// via a real override synthesized from the style, so it works even when the
		// template doesn't publish "Size".
		let sizeParam = settings.allParams.first(where: { $0.isTextSize })
		if let sizeKey = settings.textSizeKey ?? sizeParam?.styleKey {
			let size = Double(max(10, Int(textStyle.textSize)))
			entries.append(
				FCPXMLBuilder.PublishedParamEntry(name: "Size", key: sizeKey, value: "\(size)"))
		}
		return entries
	}
}
