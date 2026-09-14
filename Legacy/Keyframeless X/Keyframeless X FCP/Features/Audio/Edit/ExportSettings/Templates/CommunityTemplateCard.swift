/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct CommunityTemplateCard: View {
	let template: CommunityTemplate
	let isInstalled: Bool
	let onDownload: () -> Void
	var onUpdate: (() -> Void)?

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
						if isInstalled {
							if isHovered, let onUpdate {
								Button {
									onUpdate()
								} label: {
									Image(systemName: "arrow.up.circle.fill")
										.font(.system(size: 16))
										.foregroundStyle(.secondary)
										.padding(KKPaddingLG)
										.contentShape(Rectangle())
								}
								.buttonStyle(.plain)
							}
						} else {
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

			HStack {
				Text(template.name)
					.font(.system(size: 9))
					.foregroundStyle(.secondary)
					.lineLimit(1)
				if !template.author.isEmpty {
					Spacer()
					InfoBadge(label: template.author, systemImage: "person.fill", color: .kkAccent)
				}
			}
			.frame(height: 9)
			.padding(.horizontal, KKPaddingMD)
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

			guard let source = CGImageSourceCreateWithData(data as CFData, nil),
				let image = CaptionTemplate.gifMiddleFrame(from: source)
			else { return }

			await MainActor.run {
				thumbnail = image
				gifLocalURL = tempURL
			}
		} catch {}
	}
}
