/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

private let cardAspect: CGFloat = 16.0 / 9.0
private let selectionInset: CGFloat = 3

struct CommunityTemplateCard: View {
	let template: CommunityTemplate
	let onDownload: () -> Void

	@State private var gifData: Data?
	@State private var gifLocalURL: URL?
	@State private var thumbnail: NSImage?
	@State private var isHovered = false
	@State private var gifProgress: CGFloat = 0

	var body: some View {
		VStack(spacing: KKSpacingSM) {
			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.fill(Color.white.opacity(0.06))
				if isHovered, let gifLocalURL {
					GeometryReader { geo in
						AnimatedGifView(url: gifLocalURL, progress: $gifProgress)
							.frame(width: geo.size.width, height: geo.size.height)
					}
				} else if let thumbnail {
					Image(nsImage: thumbnail)
						.resizable()
						.aspectRatio(contentMode: .fill)
				} else {
					ProgressView()
						.controlSize(.small)
				}
				VStack {
					Spacer()
					HStack {
						Spacer()
						Button {
							onDownload()
						} label: {
							Image(systemName: "arrow.down.circle.fill")
								.font(.system(size: 16))
								.foregroundStyle(Color.kkAccent)
								.padding(KKPaddingLG)
								.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}
			}
			.overlay(alignment: .top) {
				if template.perWord {
					InfoBadge(
						label: "Per word",
						systemImage: "directcurrent",
						color: .green
					)
					.padding(KKPaddingMD)
				}
			}
			.overlay(alignment: .bottom) {
				if isHovered && gifLocalURL != nil {
					GeometryReader { geo in
						Color.kkAccent
							.frame(width: geo.size.width * gifProgress, height: 2)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: 2)
				}
			}
			.aspectRatio(cardAspect, contentMode: .fit)
			.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(
						Color.secondary.opacity(isHovered ? 0.4 : 0.2),
						lineWidth: KKBorderWidthXS
					)
			)
			.padding(selectionInset)

			Text(template.name)
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.onHover { hovering in
			isHovered = hovering
			if !hovering { gifProgress = 0 }
		}
		.task { await loadPreview() }
	}

	private func loadPreview() async {
		do {
			let (data, _) = try await URLSession.shared.data(from: template.previewGifURL)
			await MainActor.run { gifData = data }

			let tempURL = FileManager.default.temporaryDirectory
				.appendingPathComponent("\(template.id)-preview.gif")
			try data.write(to: tempURL)

			guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
			let count = CGImageSourceGetCount(source)
			guard count > 0 else { return }
			let middleIndex = count / 2
			guard let cgImage = CGImageSourceCreateImageAtIndex(source, middleIndex, nil)
			else { return }
			let image = NSImage(
				cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

			await MainActor.run {
				thumbnail = image
				gifLocalURL = tempURL
			}
		} catch {}
	}
}
