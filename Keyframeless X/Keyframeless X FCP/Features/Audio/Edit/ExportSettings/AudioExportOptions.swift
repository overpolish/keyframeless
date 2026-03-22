/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AudioExportOptionsView: View {
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
			ProjectSettingsHeader(model: model).padding(.bottom, KKPaddingMD)
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
					label: "Max Words", value: $model.maxWordsPerLine, range: 1...10,
					step: 1, valueWidth: 16
				).padding(.trailing, KKSpacingMD)
				HStack(spacing: KKSpacingLG) {
					PillToggle(
						selection: $model.captionLines,
						options: [
							(label: "One", value: AudioModel.CaptionLineCount.one),
							(label: "Two", value: AudioModel.CaptionLineCount.two),
						]
					)
					Text("Lines")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			HStack(alignment: .center, spacing: KKSpacingMD) {
				CapsuleToggle(
					isOn: $model.allCaps,
					label: "ALL CAPS",
					systemImage: "textformat"
				)
				CapsuleToggle(
					isOn: $model.censorProfanity,
					label: "Censor Profanity",
					systemImage: "checkmark.circle.trianglebadge.exclamationmark.fill"
				)
				Divider().frame(height: 12).padding(.horizontal, KKPaddingMD)
				CapsuleToggle(
					isOn: $model.stripPunctuation,
					label: "Strip Punctuation",
					systemImage: "xmark.triangle.circle.square.fill"
				)
				CapsuleToggle(
					isOn: $model.keepQuestionMarks,
					label: "Keep",
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
				.foregroundStyle(Color(nsColor: .accent() ?? .blue))
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
				selectedTemplate: $model.selectedTemplate,
				templates: model.captionTemplates,
				onDropMoti: { model.addCustomTemplate(from: $0) },
				onRemoveCustom: { model.removeCustomTemplate($0) }
			)
		}
		.onAppear {
			if !model.exportSettingsInitialized {
				let format = model.projectFormat ?? .default
				model.exportWidth = "\(format.width)"
				model.exportHeight = "\(format.height)"
				model.exportFramerate = Framerate.from(frameDuration: format.frameDuration)
				model.exportSettingsInitialized = true
			}
			initialTextStyle = TextStyleDefaults.shared.settings
			initialCaptionStyle = CaptionStyleDefaults.shared.settings
		}
	}
}

struct AudioExportOptionsSidebar: View {
	@ObservedObject var model: AudioModel
	let rows: [AudioEditRow]
	let srtHasOverlaps: Bool

	private var hasTranscribedSelection: Bool {
		let selected = model.editSelectedClips ?? Set(model.audioClips.indices)
		return rows.contains { !$0.isHeader && $0.isTranscribed && selected.contains($0.clipIndex) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			Text("Export Settings")
				.font(.title3)
				.foregroundStyle(.secondary)
			VStack(spacing: KKSpacingLG) {
				AudioExportOptionsView(model: model)
				Spacer()
				HStack(spacing: KKSpacingLG) {
					FCPDragZoneView(
						xmlProvider: { model.buildFCPXML(from: rows) },
						onDragStateChanged: { model.isDraggingToFCP = $0 }
					)
					.frame(height: 40)
					.allowsHitTesting(hasTranscribedSelection)
					.opacity(hasTranscribedSelection ? 1 : 0.4)
					SRTExportButton(
						hasOverlaps: srtHasOverlaps,
						action: { model.exportSRT(from: rows) }
					)
					.allowsHitTesting(hasTranscribedSelection)
					.opacity(hasTranscribedSelection ? 1 : 0.4)
				}
			}
			.padding(KKPaddingXL)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD + 4))
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.fill(Color.white.opacity(0.04))
			)
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
			)
		}
	}
}
