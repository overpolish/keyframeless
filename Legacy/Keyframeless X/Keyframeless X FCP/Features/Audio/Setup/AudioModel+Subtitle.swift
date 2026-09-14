/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Everything specific to the FCP 12.3 built-in Subtitle: the curated param spec, loading it into
/// the store, and the `active*` accessors that let the shared title fcpxml/native builders serve
/// both custom Titles and Subtitles. Keys live in [[SubtitleParamKey]].
extension AudioModel {

	/// The template driving export: the picked Title template, or the built-in Subtitle when in
	/// subtitles mode. Lets the title fcpxml + native builders serve both unchanged.
	var activeTemplate: CaptionTemplate {
		captionImportType == .subtitles ? .subtitle : selectedTemplate
	}

	/// Every Steno title (custom Title templates AND the built-in Subtitle) uses FCP's
	/// `subtitles` role. It's a plain role string, so it works on every version and stays stable
	/// across the 12.3 boundary: FCP resolves it to the built-in Subtitles role on 12.3+, and
	/// creates it as a custom role pre-12.3.
	var activeRole: String { "subtitles.subtitles-1" }

	/// Native (pasteboard) role UID matching `activeRole`. Same UID on every version so a
	/// pasted title carries a stable role that FCP 12.3+ resolves to the built-in Subtitles role.
	var activeRoleUID: String { "V+jNwYwqOSfaYFNdk7x48qw" }

	/// font/size/colour source: the Subtitle panel's own Font/Font Size/Text Color controls in
	/// subtitles mode, else the shared TextSettingsPanel.
	var activeTextStyle: TextStyleSettings {
		captionImportType == .subtitles ? subtitleTextStyle() : textStyle
	}

	/// Extra `<text-style>` attributes: filter attrs for both, plus the Subtitle's fixed
	/// bold/lineSpacing.
	var activeTextStyleFilterAttrs: String {
		var attrs = enabledTextFilterAttrs()
		if captionImportType == .subtitles { attrs += " bold=\"1\" lineSpacing=\"22\"" }
		return attrs
	}

	/// Param "objectID/channelPath" keys that ride in `<text-style>` and so must NOT also be
	/// emitted as param overrides. Only the Subtitle's Font/Size/Colour; empty for titles.
	var textStyleParamKeys: Set<String> {
		captionImportType == .subtitles
			? [SubtitleParamKey.font, SubtitleParamKey.fontSize, SubtitleParamKey.textColor] : []
	}

	/// The `<text-style>` for a subtitle, sourced from the Subtitle panel's Font / Font Size /
	/// Text Color controls (FCP keeps these in the text-style, not as param overrides).
	func subtitleTextStyle() -> TextStyleSettings {
		let store = TemplatePublishedParamsStore.shared
		let tid = CaptionTemplate.subtitle.id
		let params = store.params(for: tid)?.allParams ?? []
		func param(_ key: String) -> PublishedParameter? {
			params.first { "\($0.objectID)/\($0.channelPath)" == key }
		}
		var font = "HelveticaNeue"
		if let p = param(SubtitleParamKey.font) {
			font = store.value(paramID: p.id, for: tid).customFont ?? p.defaultFont ?? font
		}
		var size = 100.0
		if let p = param(SubtitleParamKey.fontSize) {
			size = store.value(paramID: p.id, for: tid).sliderValue
		}
		var r = 1.0, g = 1.0, b = 1.0, a = 1.0
		if let p = param(SubtitleParamKey.textColor) {
			let v = store.value(paramID: p.id, for: tid)
			(r, g, b, a) = (v.r, v.g, v.b, v.a)
		}
		return TextStyleSettings(
			textWidthPercent: 100, textSize: size, textYPosition: 50,
			textFont: font, textColorR: r, textColorG: g, textColorB: b, textColorA: a)
	}

	/// Per-param control config for the built-in Subtitle title, keyed by [[SubtitleParamKey]]
	/// (Motion factory channel ids - fixed for FCP's built-in Subtitle, so not name-brittle).
	/// Also defines the panel ORDER (matches FCP's inspector). Params absent here (e.g. the
	/// internal "Graphics HDR Level") are dropped. Numeric defaults override the moti's raw value
	/// where FCP shows a different neutral (offsets are 0-centred; opacity is a percent).
	private struct SubtitleSpec {
		let key: String
		let kind: PublishedParameter.ParamKind
		let defaultNumber: Double?
		/// The full FCP effect-value key for the `<param>` override. Derived from the moti scene
		/// graph: rig widgets sit under scenenode 3336678691's rig param (100); background/text
		/// layers use their scene-tree path. nil for Font/Size/Colour (they ride in <text-style>).
		let fcpKey: String?
		/// Display half-range for a 0-centred field (FCP shows these normalized params in units;
		/// e.g. Background Width ±100, X Offset ±2000). nil = value emitted as-is.
		var halfRange: Double? = nil
	}

	private static let subtitleSpecs: [SubtitleSpec] = [
		SubtitleSpec(key: SubtitleParamKey.animationStyle, kind: .dropdown, defaultNumber: nil, fcpKey: "9999/3336678691/100/3336692171/2/100"),
		SubtitleSpec(key: SubtitleParamKey.animateBy, kind: .dropdown, defaultNumber: nil, fcpKey: "9999/3336678691/100/3336679301/2/100"),
		SubtitleSpec(key: SubtitleParamKey.font, kind: .font, defaultNumber: nil, fcpKey: nil),
		SubtitleSpec(key: SubtitleParamKey.fontSize, kind: .slider, defaultNumber: 100, fcpKey: nil),
		SubtitleSpec(key: SubtitleParamKey.textColor, kind: .color, defaultNumber: nil, fcpKey: nil),
		SubtitleSpec(key: SubtitleParamKey.highlight, kind: .color, defaultNumber: nil, fcpKey: "9999/3336674837/3337240802/2/353/113/111"),
		SubtitleSpec(key: SubtitleParamKey.backgroundColor, kind: .color, defaultNumber: nil, fcpKey: "9999/3336674837/3336685305/3336678548/2/353/113/111"),
		SubtitleSpec(key: SubtitleParamKey.opacity, kind: .percent, defaultNumber: 85, fcpKey: "9999/3336674837/3336685305/3336678548/1/200/202"),
		SubtitleSpec(key: SubtitleParamKey.cornerRadius, kind: .slider, defaultNumber: 20, fcpKey: "9999/3336674837/3336685305/3336678548/2/353/144"),
		SubtitleSpec(key: SubtitleParamKey.width, kind: .slider, defaultNumber: 0, fcpKey: "9999/3336678691/100/3336678692/2/100", halfRange: 100),  // ±100, 0 = neutral
		SubtitleSpec(key: SubtitleParamKey.height, kind: .slider, defaultNumber: 0, fcpKey: "9999/3336678691/100/3336678786/2/100", halfRange: 100),  // ±100, 0 = neutral
		SubtitleSpec(key: SubtitleParamKey.xOffset, kind: .slider, defaultNumber: 0, fcpKey: "9999/3336678691/100/3337241478/2/100", halfRange: 2000),  // ±2000, 0 = neutral
		SubtitleSpec(key: SubtitleParamKey.yOffset, kind: .slider, defaultNumber: 0, fcpKey: "9999/3336678691/100/3337241559/2/100", halfRange: 2000),  // ±2000, 0 = neutral
		SubtitleSpec(key: SubtitleParamKey.socialSafe, kind: .toggle, defaultNumber: nil, fcpKey: "9999/3336678691/100/3337013104/2/100"),
	]

	/// Parse the built-in Subtitle template's published params and register them, curated by
	/// `subtitleSpecs` (kind, default, order, and which params to show). No-op on hosts without
	/// the Subtitles feature. Re-parsed each launch so it tracks FCP updates.
	func loadSubtitleParamsIfSupported() {
		guard FCPHost.supportsSubtitles else { return }
		let template = CaptionTemplate.subtitle
		guard let url = template.resolvedMotiURL() else { return }
		let result = PublishedParameter.parseAll(from: url)
		let byKey = Dictionary(
			result.customParams.map { ("\($0.objectID)/\($0.channelPath)", $0) },
			uniquingKeysWith: { first, _ in first })
		var configured: [PublishedParameter] = Self.subtitleSpecs.compactMap { spec in
			guard var p = byKey[spec.key] else { return nil }
			p.kind = spec.kind
			if let d = spec.defaultNumber { p.defaultNumber = d }
			p.normalizedHalfRange = spec.halfRange
			// The moti-derived effect-value key (the parser can't infer the rig node); both the
			// FCPXML and native export paths read styleKey first.
			if let fcpKey = spec.fcpKey { p.styleKey = fcpKey }
			p.isTextSize = false  // show Font Size as a value, don't fold it into caption Text Size
			return p
		}
		// Vertical Alignment isn't published by the moti, but the text layout exposes it on the
		// standard 2/373/2 channel (same one the custom-title vertical alignment drives, so the
		// native path's verticalAlignmentTag() picks it up). Synthesize it as a Top/Center/Bottom
		// dropdown defaulting to Bottom, placed right after Font Size.
		let verticalAlignment = PublishedParameter(
			name: "Vertical Alignment",
			objectID: "3336674846",
			channel: "./2/373/2",
			kind: .dropdown,
			options: [
				.init(name: "Top", tag: 0),
				.init(name: "Center", tag: 1),
				.init(name: "Bottom", tag: 2),
			],
			defaultTag: 2,
			styleKey: "9999/3336674837/3336674846/2/373/2",
			nativeFlags: 8_606_777_360
		)
		if let fontSizeIdx = configured.firstIndex(where: {
			$0.objectID == "3336674848" && $0.channelPath == "3"
		}) {
			configured.insert(verticalAlignment, at: fontSizeIdx + 1)
		} else {
			configured.append(verticalAlignment)
		}
		TemplatePublishedParamsStore.shared.setParams(
			configured, hasPerWordAnimation: result.hasPerWordAnimation,
			textOzml: result.textOzml, for: template.id)
	}
}
