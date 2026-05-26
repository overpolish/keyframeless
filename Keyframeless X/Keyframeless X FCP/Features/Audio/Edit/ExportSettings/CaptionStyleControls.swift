/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct CaptionStyleControls: View {
	@ObservedObject var model: AudioModel
	@State private var initialTextStyle: TextStyleSettings?
	@State private var initialCaptionStyle: CaptionStyleSettings?

	private var hasChanges: Bool {
		if let initialTextStyle, model.textStyle != initialTextStyle { return true }
		if let initialCaptionStyle, model.captionStyle != initialCaptionStyle { return true }
		return false
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			GeometryReader { geo in
				let halfWidth = (geo.size.width - KKSpacingXL) / 2
				HStack(alignment: .bottom, spacing: KKSpacingXL) {
					TextSettingsPanel(model: model)
						.frame(width: halfWidth)
					DimensionsPreview(model: model)
						.frame(width: halfWidth)
				}
			}
			.frame(height: 100)
			HStack(spacing: KKSpacingLG) {
				LabeledSlider(
					label: String(localized: "Max Words"), value: $model.maxWordsPerLine,
					range: 1...10,
					step: 1, valueWidth: 16
				).padding(.trailing, KKSpacingMD)
				HStack(spacing: KKSpacingLG) {
					PillToggle(
						selection: $model.captionLines,
						options: [
							(label: String(localized: "One"), value: CaptionLineCount.one),
							(label: String(localized: "Two"), value: CaptionLineCount.two),
						]
					)
					Text("Lines")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			FlowLayout(spacing: KKSpacingMD, lineSpacing: KKSpacingSM) {
				CapsuleToggle(
					isOn: $model.allCaps,
					label: String(localized: "ALL CAPS"),
					systemImage: "textformat"
				)
				CapsuleToggle(
					isOn: $model.noGaps,
					label: String(localized: "No Gaps"),
					systemImage: "arrow.down.right.and.arrow.up.left"
				)
				CapsuleToggle(
					isOn: $model.censorProfanity,
					label: String(localized: "Censor"),
					systemImage: "exclamationmark.bubble.fill"
				)
				CapsuleToggle(
					isOn: $model.stripPunctuation,
					label: String(localized: "Strip Punctuation"),
					systemImage: "xmark.triangle.circle.square.fill"
				)
				CapsuleToggle(
					isOn: $model.keepQuestionMarks,
					label: String(localized: "Keep"),
					systemImage: "questionmark",
					disabled: !model.stripPunctuation
				)
			}.frame(maxWidth: .infinity)
			HStack(spacing: KKSpacingLG) {
				Button {
					TextStyleDefaults.shared.save(model.textStyle)
					CaptionStyleDefaults.shared.save(model.captionStyle)
					initialTextStyle = model.textStyle
					initialCaptionStyle = model.captionStyle
				} label: {
					Label("Make Default", systemImage: "star")
						.font(.system(size: 10))
						.padding(.horizontal, KKPaddingLG)
						.padding(.vertical, KKSpacingSM)
						.contentShape(Capsule())
				}
				.buttonStyle(.plain)
				.foregroundStyle(Color.kkAccent)
				Spacer()
				if hasChanges {
					Button {
						model.textStyle = initialTextStyle ?? TextStyleDefaults.shared.settings
						model.captionStyle =
							initialCaptionStyle ?? CaptionStyleDefaults.shared.settings
					} label: {
						Label("Reset", systemImage: "arrow.uturn.backward")
							.font(.system(size: 10))
							.padding(.horizontal, KKPaddingLG)
							.padding(.vertical, KKSpacingSM)
							.contentShape(Capsule())
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				}
			}
			Divider()
			CaptionTemplatePicker(
				model: model,
				templates: model.captionTemplates,
				onDropMoti: { model.addCustomTemplate(from: $0) },
				onRemoveCustom: { model.removeCustomTemplate($0) }
			)
		}
		.onAppear {
			initialTextStyle = TextStyleDefaults.shared.settings
			initialCaptionStyle = CaptionStyleDefaults.shared.settings
		}
	}
}
