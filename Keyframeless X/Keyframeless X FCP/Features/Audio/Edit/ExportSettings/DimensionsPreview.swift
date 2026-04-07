/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct DimensionsPreview: View {
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
		guard container.width > 0 && container.height > 0 else { return .zero }
		let videoAspect = exportWidth / exportHeight
		let containerAspect = container.width / container.height
		if videoAspect > containerAspect {
			return CGSize(width: container.width, height: container.width / videoAspect)
		} else {
			return CGSize(width: container.height * videoAspect, height: container.height)
		}
	}

	var body: some View {
		GeometryReader { geo in
			let fit = fitSize(in: geo.size)
			let scaleFactor = fit.width / exportWidth
			let textWidthExport = exportWidth * CGFloat(model.textWidthPercent / 100)
			let fcpFontSize = max(model.textSize * (exportHeight / 1080.0), 2)
			let fullFont =
				NSFont(name: model.textFont, size: fcpFontSize)
				?? NSFont.systemFont(ofSize: fcpFontSize)
			let yOffsetExport =
				exportHeight * CGFloat(50 - model.textYPosition) / 100 + fullFont.capHeight / 3

			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusSM)
					.fill(Color.white.opacity(0.08))
					.frame(width: fit.width, height: fit.height)
					.overlay {
						Text(previewText(availableWidth: textWidthExport, font: fullFont))
							.font(.custom(model.textFont, size: fcpFontSize))
							.lineSpacing(fcpFontSize * 0.3)
							.foregroundStyle(
								Color(
									red: model.textColorR,
									green: model.textColorG,
									blue: model.textColorB,
									opacity: model.textColorA
								)
							)
							.multilineTextAlignment(.center)
							.fixedSize(horizontal: true, vertical: true)
							.offset(y: yOffsetExport)
							.frame(width: exportWidth, height: exportHeight)
							.scaleEffect(scaleFactor)
					}
					.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
					.shadow(color: .black.opacity(0.4), radius: 4, y: 2)
			}
			.frame(width: geo.size.width, height: geo.size.height)
		}
	}
}
