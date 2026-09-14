/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

/// A hand-grouped layout for the built-in Subtitle's published params. The Subtitle is a fixed,
/// fully-curated built-in (unlike adaptive custom templates), so we can pair related fields onto
/// single rows - nicer to traverse and less scrolling than FCP's own flat inspector.
struct SubtitleStylePanel: View {
	@ObservedObject var store: TemplatePublishedParamsStore

	private let tid = CaptionTemplate.subtitle.id
	private let controlsWidth: CGFloat = 190
	private typealias K = SubtitleParamKey

	private var params: [PublishedParameter] { store.params(for: tid)?.allParams ?? [] }

	private func param(_ key: String) -> PublishedParameter? {
		params.first { "\($0.objectID)/\($0.channelPath)" == key }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			if params.isEmpty {
				Spacer()
				Text("No options to customise")
					.font(.system(size: 9))
					.foregroundStyle(.secondary.opacity(0.6))
					.frame(maxWidth: .infinity)
				Spacer()
			} else {
				ScrollShadowView(cornerRadius: KKRadiusSM) {
					VStack(alignment: .leading, spacing: KKSpacingLG) {
						rows
					}
					.padding(.vertical, KKPaddingXS)
				}
			}
		}
		.frame(maxHeight: .infinity)
	}

	@ViewBuilder private var rows: some View {
		// Animation: Style + By
		pairRow(String(localized: "Animation"), K.animationStyle, K.animateBy)
		// Font + Font Size
		if let font = param(K.font), let size = param(K.fontSize) {
			row(String(localized: "Font")) {
				HStack(spacing: KKSpacingSM) {
					FontFieldControl(
						param: font, templateID: tid, store: store, arrowEdge: .leading
					)
					.frame(maxWidth: .infinity)
					ParamControl(param: size, templateID: tid, store: store).frame(width: 52)
				}
			}
		}
		singleRow(K.textColor)
		singleRow(K.highlight)
		singleRow(K.backgroundColor)
		singleRow(K.opacity)
		singleRow(K.cornerRadius)
		// Background Size: Width × Height
		if let w = param(K.width), let h = param(K.height) {
			row(String(localized: "Background Size")) {
				HStack(spacing: KKSpacingSM) {
					ParamControl(param: w, templateID: tid, store: store)
						.frame(maxWidth: .infinity)
					Text("\u{00d7}").font(.system(size: 11)).foregroundStyle(.secondary)
					ParamControl(param: h, templateID: tid, store: store)
						.frame(maxWidth: .infinity)
				}
			}
		}
		// Position Offset: X / Y
		if let x = param(K.xOffset), let y = param(K.yOffset) {
			row(String(localized: "Position Offset")) {
				HStack(spacing: KKSpacingSM) {
					axisField("X", x)
					axisField("Y", y)
				}
			}
		}
		singleRow(K.verticalAlignment)
		singleRow(K.socialSafe)
	}

	/// A row: label on the left (grows), controls pinned right at a fixed width so every row's
	/// field edge lines up.
	private func row<Content: View>(
		_ label: String, @ViewBuilder _ content: () -> Content
	) -> some View {
		HStack(spacing: KKSpacingMD) {
			Text(label)
				.font(.system(size: 10))
				.foregroundStyle(.primary)
				.lineLimit(1)
			Spacer(minLength: KKSpacingMD)
			content().frame(width: controlsWidth, alignment: .trailing)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// A single param on its own row, labelled by its (localized) name. The Subtitle's param
	/// names are Apple's fixed English strings, so they localize via the catalog (unlike custom
	/// templates' arbitrary creator names, which pass through raw).
	@ViewBuilder private func singleRow(_ key: String) -> some View {
		if let p = param(key) {
			row(String(localized: String.LocalizationValue(p.name))) {
				ParamControl(param: p, templateID: tid, store: store)
			}
		}
	}

	/// Two params side by side under one shared label.
	@ViewBuilder private func pairRow(_ label: String, _ keyA: String, _ keyB: String) -> some View
	{
		if let a = param(keyA), let b = param(keyB) {
			row(label) {
				HStack(spacing: KKSpacingSM) {
					ParamControl(param: a, templateID: tid, store: store)
						.frame(maxWidth: .infinity)
					ParamControl(param: b, templateID: tid, store: store)
						.frame(maxWidth: .infinity)
				}
			}
		}
	}

	/// A numeric field prefixed with its axis label (X / Y), bound to the param's slider value.
	private func axisField(_ axis: String, _ p: PublishedParameter) -> some View {
		let value = Binding(
			get: { store.value(paramID: p.id, for: tid).sliderValue },
			set: { v in
				var val = store.value(paramID: p.id, for: tid)
				val.sliderValue = v
				store.setValue(val, paramID: p.id, for: tid)
			})
		return HStack(spacing: KKSpacingXS) {
			Text(axis)
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(.secondary)
				.fixedSize()
			TextField(
				"", value: value, format: .number.precision(.fractionLength(0)).grouping(.never)
			)
			.textFieldStyle(.plain)
			.font(.system(size: 11).monospacedDigit())
			.multilineTextAlignment(.trailing)
			.frame(maxWidth: .infinity)
		}
		.frame(height: KKInspectorRowHeight)
		.padding(.horizontal, KKPaddingLG)
		.kkPanel(cornerRadius: KKRadiusMD)
		.frame(maxWidth: .infinity)
	}
}
