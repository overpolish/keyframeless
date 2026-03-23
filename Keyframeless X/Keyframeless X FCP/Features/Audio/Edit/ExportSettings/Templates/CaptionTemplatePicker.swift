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
	@ObservedObject var model: AudioModel
	let templates: [CaptionTemplate]
	var onDropMoti: ((URL) -> Void)?
	var onRemoveCustom: ((CaptionTemplate) -> Void)?

	@ObservedObject private var favorites = TemplateFavorites.shared
	@ObservedObject private var paramsStore = TemplatePublishedParamsStore.shared
	@State private var isDropTargeted = false
	@State private var searchText = ""
	@State private var showFavoritesOnly = false
	@State private var showPerWordOnly = false
	@State private var showControlsPopover = false

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

	private var hasEnabledControls: Bool {
		guard let settings = paramsStore.params(for: model.selectedTemplate.id) else {
			return false
		}
		return settings.allParams.contains {
			settings.enabledIDs.contains($0.id) && $0.isToggleable
		}
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
				Spacer()
				if hasEnabledControls {
					Button {
						showControlsPopover.toggle()
					} label: {
						Image(systemName: "paintpalette.fill")
							.font(.system(size: 11))
							.foregroundStyle(showControlsPopover ? Color.kkAccent : .secondary)
							.frame(maxHeight: .infinity)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.popover(isPresented: $showControlsPopover, arrowEdge: .trailing) {
						TemplateControlsPopover(
							template: model.selectedTemplate,
							store: paramsStore
						)
					}
				}
			}
			.fixedSize(horizontal: false, vertical: true)
			ScrollShadowView(cornerRadius: KKRadiusSM, scrollToID: model.selectedTemplate.id) {
				VStack(alignment: .leading, spacing: KKSpacingLG) {
					TemplateSection(title: "Keyframeless") {
						ForEach(keyframelessTemplates) { template in
							CaptionTemplateCard(
								template: template,
								isSelected: template.id == model.selectedTemplate.id,
								isFavorite: favorites.contains(template.id),
								onSelect: { model.selectedTemplate = template },
								onToggleFavorite: { favorites.toggle(template.id) }
							)
							.id(template.id)
						}
					}
					TemplateSection(title: "Custom") {
						ForEach(customTemplates) { template in
							CaptionTemplateCard(
								template: template,
								isSelected: template.id == model.selectedTemplate.id,
								isFavorite: favorites.contains(template.id),
								onSelect: { model.selectedTemplate = template },
								onToggleFavorite: { favorites.toggle(template.id) },
								onRemove: { onRemoveCustom?(template) },
								onSettings: { showParamsModal(for: template) },
								onPublish: { model.publishModalTemplate = template }
							)
							.id(template.id)
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
		addMotiAndDetectParams(url)
	}

	private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
				guard let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					url.pathExtension.lowercased() == "moti"
				else { return }
				DispatchQueue.main.async { addMotiAndDetectParams(url) }
			}
		}
		return true
	}

	private func addMotiAndDetectParams(_ url: URL) {
		let result = PublishedParameter.parseAll(from: url)
		onDropMoti?(url)
		guard !result.customParams.isEmpty else { return }
		let templateID = "custom:\(url.path)"
		DispatchQueue.main.async {
			if let added = templates.first(where: { $0.id == templateID }) {
				model.paramsModalParams = result.customParams
				model.paramsModalHasPerWord = result.hasPerWordAnimation
				model.paramsModalTemplate = added
			}
		}
	}

	private func showParamsModal(for template: CaptionTemplate) {
		let existing = paramsStore.params(for: template.id)
		if let url = resolveMotiURL(for: template) {
			let result = PublishedParameter.parseAll(from: url)
			model.paramsModalParams = result.customParams
			model.paramsModalHasPerWord = result.hasPerWordAnimation
		} else if let existing {
			model.paramsModalParams = existing.allParams
			model.paramsModalHasPerWord = existing.hasPerWordAnimation
		} else {
			model.paramsModalParams = []
			model.paramsModalHasPerWord = false
		}
		model.paramsModalTemplate = template
	}

	private func resolveMotiURL(for template: CaptionTemplate) -> URL? {
		let uid = template.uid
		if uid.hasPrefix("~/") {
			let relative = String(uid.dropFirst(2))
			let base = FileManager.default.homeDirectoryForCurrentUser
				.appendingPathComponent("Movies/Motion Templates.localized")
			return base.appendingPathComponent(relative)
		}
		return URL(fileURLWithPath: uid)
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
