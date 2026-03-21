/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
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
		}
		.onAppear {
			if !model.exportSettingsInitialized {
				let format = model.projectFormat ?? .default
				model.exportWidth = "\(format.width)"
				model.exportHeight = "\(format.height)"
				model.exportFramerate = Framerate.from(frameDuration: format.frameDuration)
				model.exportSettingsInitialized = true
			}
			initialTextStyle = model.textStyle
			initialCaptionStyle = model.captionStyle
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
				.font(.caption)
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
			FrameratePickerButton(selection: $model.exportFramerate)
		}
	}
}

private struct TextSettingsPanel: View {
	@ObservedObject var model: AudioModel

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
		}
	}
}

private struct DimensionsPreview: View {
	@ObservedObject var model: AudioModel

	private static let sampleWords = [
		"The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog", "nearby",
		"while", "the", "cat", "sleeps", "under", "a", "warm", "golden", "sun", "today",
		"and", "birds", "sing", "softly", "in", "the", "tall", "green", "trees", "above",
	]

	private var exportWidth: CGFloat { CGFloat(Int(model.exportWidth) ?? 1920) }
	private var exportHeight: CGFloat { CGFloat(Int(model.exportHeight) ?? 1080) }

	private func previewText(availableWidth: CGFloat, font: NSFont) -> String {
		let maxWords = Int(model.maxWordsPerLine)
		let lineCount = model.captionLines == .two ? 2 : 1
		let attrs: [NSAttributedString.Key: Any] = [.font: font]
		var lines: [String] = []
		var wordIndex = 0
		for _ in 0..<lineCount {
			var lineWords: [String] = []
			for _ in 0..<maxWords {
				guard wordIndex < Self.sampleWords.count else { break }
				let candidate = (lineWords + [Self.sampleWords[wordIndex]]).joined(separator: " ")
				let width = (candidate as NSString).size(withAttributes: attrs).width
				if !lineWords.isEmpty && width > availableWidth { break }
				lineWords.append(Self.sampleWords[wordIndex])
				wordIndex += 1
			}
			if !lineWords.isEmpty {
				lines.append(lineWords.joined(separator: " "))
			}
		}
		let text = lines.joined(separator: "\n")
		return model.allCaps ? text.uppercased() : text
	}

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
					.overlay(alignment: .bottom) {
						let textWidth = fit.width * CGFloat(model.textWidthPercent / 100)
						let nsFont =
							NSFont(name: model.textFont, size: max(fontSize, 2))
							?? NSFont.systemFont(ofSize: max(fontSize, 2))
						Text(previewText(availableWidth: textWidth, font: nsFont))
							.font(.custom(model.textFont, size: max(fontSize, 2)))
							.foregroundStyle(.white)
							.multilineTextAlignment(.center)
							.fixedSize(horizontal: true, vertical: true)
							.frame(width: textWidth)
							.offset(y: -(fit.height - textBlockY))
					}
					.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
					.shadow(color: .black.opacity(0.4), radius: 4, y: 2)
			}
			.frame(width: geo.size.width, height: geo.size.height)
		}
	}
}

struct FrameratePickerButton: View {
	@Binding var selection: Framerate
	@State private var isOpen = false

	var body: some View {
		let accent = Color(nsColor: .accent() ?? .blue)

		HStack(spacing: KKSpacingSM) {
			Text(selection.label)
			Spacer()
			Image(systemName: "chevron.up.chevron.down")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.frame(width: 80)
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKPaddingXS)
		.background(
			Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: KKRadiusMD)
		)
		.overlay(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
		)
		.contentShape(Rectangle())
		.onTapGesture { isOpen.toggle() }
		.popover(isPresented: $isOpen, arrowEdge: .top) {
			VStack(spacing: 0) {
				ForEach(Framerate.allCases) { rate in
					HStack {
						Text(rate.label)
							.font(.system(size: 12))
						Spacer()
					}
					.padding(.horizontal, KKPaddingLG)
					.padding(.vertical, KKSpacingMD)
					.background(
						RoundedRectangle(cornerRadius: KKRadiusMD)
							.fill(selection == rate ? accent.opacity(0.12) : Color.clear)
					)
					.contentShape(Rectangle())
					.onTapGesture {
						selection = rate
						isOpen = false
					}
				}
			}
			.padding(KKPaddingMD)
			.background(PopoverBackgroundClearer())
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
