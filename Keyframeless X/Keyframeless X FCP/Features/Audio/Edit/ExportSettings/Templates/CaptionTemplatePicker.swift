/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

private let cardAspect: CGFloat = 16.0 / 9.0
private let cardMinWidth: CGFloat = 160
private let cardSpacing = KKSpacingLG
private let selectionInset: CGFloat = 3

struct CaptionTemplatePicker: View {
	@Binding var selectedTemplate: CaptionTemplate
	let templates: [CaptionTemplate]
	var onDropMoti: ((URL) -> Void)?
	var onRemoveCustom: ((CaptionTemplate) -> Void)?

	@ObservedObject private var favorites = TemplateFavorites.shared
	@State private var isDropTargeted = false
	@State private var searchText = ""
	@State private var showFavoritesOnly = false
	@State private var showPerWordOnly = false

	private func sorted(_ list: [CaptionTemplate]) -> [CaptionTemplate] {
		list.sorted { a, b in
			let aFav = favorites.contains(a.id)
			let bFav = favorites.contains(b.id)
			if aFav != bFav { return aFav }
			return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
		}
	}

	private func filtered(_ list: [CaptionTemplate]) -> [CaptionTemplate] {
		var result = list
		if showFavoritesOnly {
			result = result.filter { favorites.contains($0.id) }
		}
		if showPerWordOnly {
			result = result.filter { $0.supportsPerWordAnimation }
		}
		if !searchText.isEmpty {
			result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
		}
		return sorted(result)
	}

	private var keyframelessTemplates: [CaptionTemplate] {
		filtered(templates.filter { !$0.isCustom })
	}

	private var customTemplates: [CaptionTemplate] {
		filtered(templates.filter { $0.isCustom })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			HStack(spacing: KKSpacingMD) {
				Text("Style")
					.font(.title3)
					.foregroundStyle(.secondary)
				HStack(spacing: KKSpacingSM) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
					TemplateSearchField(text: $searchText)
						.frame(height: 16)
				}
				.padding(.horizontal, KKPaddingLG)
				.padding(.vertical, KKPaddingXS)
				.kkPanel(cornerRadius: KKRadiusMD)
				.frame(maxWidth: 120)
				Button {
					showFavoritesOnly.toggle()
				} label: {
					Image(systemName: showFavoritesOnly ? "star.fill" : "star")
						.font(.system(size: 11))
						.foregroundStyle(
							showFavoritesOnly
								? Color.kkWarning
								: .secondary
						)
						.frame(maxHeight: .infinity)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				Button {
					showPerWordOnly.toggle()
				} label: {
					Image(systemName: "directcurrent")
						.font(.system(size: 11))
						.foregroundStyle(
							showPerWordOnly
								? .green
								: .secondary
						)
						.frame(maxHeight: .infinity)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
			.fixedSize(horizontal: false, vertical: true)
			ScrollShadowView(cornerRadius: KKRadiusSM) {
				VStack(alignment: .leading, spacing: KKSpacingLG) {
					TemplateSection(title: "Keyframeless") {
						ForEach(keyframelessTemplates) { template in
							CaptionTemplateCard(
								template: template,
								isSelected: template.id == selectedTemplate.id,
								isFavorite: favorites.contains(template.id),
								onSelect: { selectedTemplate = template },
								onToggleFavorite: { favorites.toggle(template.id) }
							)
						}
					}
					TemplateSection(title: "Custom") {
						ForEach(customTemplates) { template in
							CaptionTemplateCard(
								template: template,
								isSelected: template.id == selectedTemplate.id,
								isFavorite: favorites.contains(template.id),
								onSelect: { selectedTemplate = template },
								onToggleFavorite: { favorites.toggle(template.id) },
								onRemove: { onRemoveCustom?(template) }
							)
						}
						MotiDropTarget(onPickFile: pickMotiFile)
					}
				}
				.padding(.vertical, KKPaddingXS)
			}
		}
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			handleDrop(providers)
		}
	}

	private func pickMotiFile() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "moti") ?? .data]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		onDropMoti?(url)
	}

	private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
				guard let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					url.pathExtension.lowercased() == "moti"
				else { return }
				DispatchQueue.main.async { onDropMoti?(url) }
			}
		}
		return true
	}
}

struct TemplateSection<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingSM) {
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
			TemplateGrid { content }
		}
	}
}

struct TemplateGrid<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		let gridColumns = [
			GridItem(.adaptive(minimum: cardMinWidth), spacing: cardSpacing)
		]

		LazyVGrid(columns: gridColumns, spacing: cardSpacing) {
			content
		}
	}
}

struct MotiDropTarget: View {
	var onPickFile: (() -> Void)?

	var body: some View {
		VStack(spacing: KKSpacingSM) {
			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(style: StrokeStyle(lineWidth: KKBorderWidthXS, dash: [4, 3]))
					.foregroundStyle(.secondary.opacity(0.3))
				Image(systemName: "plus")
					.font(.system(size: 14))
					.foregroundStyle(.secondary.opacity(0.5))
			}
			.aspectRatio(cardAspect, contentMode: .fit)
			.padding(selectionInset)
			Text("Drop .moti")
				.font(.system(size: 9))
				.foregroundStyle(.secondary.opacity(0.5))
		}
		.contentShape(Rectangle())
		.onTapGesture { onPickFile?() }
	}
}
