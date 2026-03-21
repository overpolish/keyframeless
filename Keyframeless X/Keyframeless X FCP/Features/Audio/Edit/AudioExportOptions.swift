/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct AudioExportOptionsView: View {
	@ObservedObject var model: AudioModel

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			ProjectSettingsHeader(model: model)
			GeometryReader { geo in
				let halfWidth = (geo.size.width - KKSpacingXL) / 2
				HStack(alignment: .top, spacing: KKSpacingXL) {
					TextSettingsPanel(model: model)
						.frame(width: halfWidth)
					DimensionsPreview(model: model)
						.frame(width: halfWidth)
				}
			}
			.frame(height: 100)
		}
		.onAppear {
			guard !model.exportSettingsInitialized else { return }
			let format = model.projectFormat ?? .default
			model.exportWidth = "\(format.width)"
			model.exportHeight = "\(format.height)"
			model.exportFramerate = Framerate.from(frameDuration: format.frameDuration)
			model.exportSettingsInitialized = true
		}
	}
}

private struct ProjectSettingsHeader: View {
	@ObservedObject var model: AudioModel

	private var projectFormat: FCPXMLParser.ProjectFormat {
		model.projectFormat ?? .default
	}

	private var hasChanges: Bool {
		model.exportWidth != "\(projectFormat.width)"
			|| model.exportHeight != "\(projectFormat.height)"
			|| model.exportFramerate != Framerate.from(frameDuration: projectFormat.frameDuration)
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text("Project Settings")
				.font(.subheadline)
				.foregroundStyle(.secondary)
			Spacer()
			if hasChanges {
				Button {
					model.exportWidth = "\(projectFormat.width)"
					model.exportHeight = "\(projectFormat.height)"
					model.exportFramerate = Framerate.from(
						frameDuration: projectFormat.frameDuration)
				} label: {
					Image(systemName: "arrow.uturn.backward")
						.font(.system(size: 10))
						.padding(.horizontal, KKPaddingSM)
						.padding(.vertical, KKSpacingSM)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
			}
			IntegerField(placeholder: "Width", text: $model.exportWidth, min: 60, max: 7680)
				.frame(width: 60)
			Text("\u{00d7}")
				.foregroundStyle(.secondary)
			IntegerField(placeholder: "Height", text: $model.exportHeight, min: 60, max: 4320)
				.frame(width: 60)
			Picker("", selection: $model.exportFramerate) {
				ForEach(Framerate.allCases) { rate in
					Text(rate.label).tag(rate)
				}
			}
			.labelsHidden()
			.frame(width: 100)
		}
	}
}

private struct TextSettingsPanel: View {
	@ObservedObject var model: AudioModel
	@State private var initialStyle: TextStyleSettings?

	private var hasChanges: Bool {
		guard let initialStyle else { return false }
		return model.textStyle != initialStyle
	}

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			FontPickerRow(selectedFont: $model.textFont)
			LabeledSlider(
				label: "Text Width", value: $model.textWidthPercent, range: 10...100,
				suffix: "%")
			LabeledSlider(
				label: "Text Size", value: $model.textSize, range: 10...200,
				suffix: "pt")
			LabeledSlider(
				label: "Y Position", value: $model.textYPosition, range: 0...100,
				suffix: "%")
			HStack(spacing: KKSpacingLG) {
				Button {
					TextStyleDefaults.shared.save(model.textStyle)
					initialStyle = model.textStyle
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
						model.textStyle = initialStyle ?? TextStyleDefaults.shared.settings
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
		}
		.onAppear {
			initialStyle = model.textStyle
		}
	}
}

private struct DimensionsPreview: View {
	@ObservedObject var model: AudioModel

	private var exportWidth: CGFloat { CGFloat(Int(model.exportWidth) ?? 1920) }
	private var exportHeight: CGFloat { CGFloat(Int(model.exportHeight) ?? 1080) }

	private func fitSize(in container: CGSize) -> CGSize {
		let boundingAspect: CGFloat = 16.0 / 9.0
		let videoAspect = exportWidth / exportHeight
		if videoAspect > boundingAspect {
			return CGSize(width: container.width, height: container.width / videoAspect)
		} else {
			return CGSize(width: container.height * videoAspect, height: container.height)
		}
	}

	var body: some View {
		GeometryReader { geo in
			let fit = fitSize(in: geo.size)
			let scaleFactor = fit.width / exportWidth
			let fontSize = model.textSize * scaleFactor
			let textBlockY = fit.height * CGFloat(1 - model.textYPosition / 100)

			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusSM)
					.fill(Color.white.opacity(0.08))
					.frame(width: fit.width, height: fit.height)
					.overlay(
						RoundedRectangle(cornerRadius: KKRadiusMD)
							.strokeBorder(Color.secondary.opacity(0.3), lineWidth: KKBorderWidthXS)
					)
					.overlay(alignment: .top) {
						Text("The quick brown fox jumps. Over the lazy dog nearby.")
							.font(.custom(model.textFont, size: max(fontSize, 2)))
							.foregroundStyle(.white)
							.lineLimit(1)
							.minimumScaleFactor(0.5)
							.frame(width: fit.width * CGFloat(model.textWidthPercent / 100))
							.offset(y: textBlockY - fontSize / 2)
					}
					.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
					.shadow(color: .black.opacity(0.4), radius: 4, y: 2)
			}
			.frame(width: geo.size.width, height: geo.size.height)
		}
	}
}

enum Framerate: String, CaseIterable, Identifiable, Codable {
	case fps2398 = "1001/24000s"
	case fps24 = "100/2400s"
	case fps25 = "100/2500s"
	case fps2997 = "1001/30000s"
	case fps30 = "100/3000s"
	case fps50 = "100/5000s"
	case fps5994 = "1001/60000s"
	case fps60 = "100/6000s"
	case fps120 = "100/12000s"

	var id: String { rawValue }

	var label: String {
		switch self {
		case .fps2398: return "23.98 fps"
		case .fps24: return "24 fps"
		case .fps25: return "25 fps"
		case .fps2997: return "29.97 fps"
		case .fps30: return "30 fps"
		case .fps50: return "50 fps"
		case .fps5994: return "59.94 fps"
		case .fps60: return "60 fps"
		case .fps120: return "120 fps"
		}
	}

	static func from(frameDuration: String) -> Framerate {
		allCases.first { $0.rawValue == frameDuration } ?? .fps30
	}
}

struct AudioExportOptionsSidebar: View {
	@ObservedObject var model: AudioModel

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			AudioExportOptionsView(model: model)
			Spacer()
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
