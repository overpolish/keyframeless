/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CaptionTemplateCard: View {
	let template: CaptionTemplate
	let isSelected: Bool
	let isFavorite: Bool
	let onSelect: () -> Void
	var onToggleFavorite: (() -> Void)?
	var onRemove: (() -> Void)?
	var onSettings: (() -> Void)?
	var onPublish: (() -> Void)?
	var onUpdate: (() -> Void)?

	@State private var thumbnail: NSImage?
	@State private var gifURL: URL?
	@State private var isHovered = false
	@State private var gifProgress: CGFloat = 0

	var body: some View {
		VStack(spacing: KKSpacingSM) {
			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.fill(Color.white.opacity(0.06))
				if isHovered, let gifURL {
					GeometryReader { geo in
						AnimatedGifView(url: gifURL, progress: $gifProgress)
							.frame(width: geo.size.width, height: geo.size.height)
					}
				} else if let thumbnail {
					Image(nsImage: thumbnail)
						.resizable()
						.aspectRatio(contentMode: .fill)
				} else {
					Image(systemName: "textformat")
						.font(.system(size: 20))
						.foregroundStyle(.secondary)
				}
				VStack(spacing: 0) {
					HStack {
						if isHovered, let onRemove {
							Button {
								onRemove()
							} label: {
								Image(systemName: "xmark.circle.fill")
									.font(.system(size: 12))
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
							.padding(KKPaddingMD)
						}
						Spacer()
						if isFavorite || isHovered {
							Button {
								onToggleFavorite?()
							} label: {
								Image(systemName: isFavorite ? "star.fill" : "star")
									.font(.system(size: 9))
									.foregroundStyle(
										isFavorite
											? Color.kkWarning
											: .secondary.opacity(0.4)
									)
									.padding(KKPaddingLG)
									.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
						}
					}
					Spacer()
					HStack {
						if isHovered, let onSettings {
							Button {
								onSettings()
							} label: {
								Image(systemName: "gearshape.fill")
									.font(.system(size: 10))
									.foregroundStyle(.secondary)
									.padding(KKPaddingMD)
									.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
						}
						Spacer()
						if isHovered, let onUpdate {
							Button {
								onUpdate()
							} label: {
								Image(systemName: "arrow.up.circle.fill")
									.font(.system(size: 10))
									.foregroundStyle(.secondary)
									.padding(KKPaddingMD)
									.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
						} else if isHovered, let onPublish {
							Button {
								onPublish()
							} label: {
								Image(systemName: "arrow.up.circle.fill")
									.font(.system(size: 10))
									.foregroundStyle(.secondary)
									.padding(KKPaddingMD)
									.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
						}
					}
				}
			}
			.overlay(alignment: .top) {
				if template.supportsPerWordAnimation {
					InfoBadge(
						label: "Per word",
						systemImage: "directcurrent",
						color: .green
					)
					.padding(KKPaddingMD)
				}
			}
			.overlay(alignment: .bottom) {
				if isHovered && gifURL != nil {
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
			.overlay(
				RoundedRectangle(cornerRadius: KKRadiusMD + selectionInset)
					.strokeBorder(
						isSelected
							? Color.kkAccent
							: .clear,
						lineWidth: KKBorderWidthSM
					)
			)

			HStack {
				Text(template.name)
					.font(.system(size: 9))
					.foregroundStyle(isSelected ? .primary : .secondary)
					.lineLimit(1)
				if let author = template.author {
					Spacer()
					InfoBadge(label: author, systemImage: "person.fill", color: .kkAccent)
				}
			}
			.frame(height: 9)
		}
		.onHover { hovering in
			isHovered = hovering
			if !hovering { gifProgress = 0 }
		}
		.onTapGesture { onSelect() }
		.onAppear {
			thumbnail = template.loadThumbnail()
			gifURL = template.loadPreviewGifURL()
		}
	}
}
