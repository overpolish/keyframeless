/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

struct CaptionTemplatePicker: View {
	@ObservedObject var model: AudioModel
	let templates: [CaptionTemplate]
	var onDropMoti: ((URL) -> Void)?
	var onRemoveCustom: ((CaptionTemplate) -> Void)?

	@ObservedObject private var favorites = TemplateFavorites.shared
	@ObservedObject private var paramsStore = TemplatePublishedParamsStore.shared
	@ObservedObject private var communityStore = CommunityTemplateStore.shared
	@State private var isDropTargeted = false
	@State private var searchText = ""
	@State private var showFavoritesOnly = false
	@State private var showPerWordOnly = false
	@State private var showCommunity = true
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

	private var filteredCommunityTemplates: [CommunityTemplate] {
		let installedNames = Set(keyframelessTemplates.map { $0.name })
		var result = communityStore.templates.filter { !installedNames.contains($0.name) }
		if showPerWordOnly {
			result = result.filter { $0.perWord }
		}
		if !searchText.isEmpty {
			result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
		}
		return result
	}

	private var mergedKeyframelessItems: [KeyframelessItem] {
		let installed = keyframelessTemplates.map { KeyframelessItem.installed($0) }
		let community =
			showCommunity ? filteredCommunityTemplates.map { KeyframelessItem.community($0) } : []
		return (installed + community).sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
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
				Button {
					showCommunity.toggle()
				} label: {
					Image(systemName: "arrow.down.circle.fill")
						.font(.system(size: 11))
						.foregroundStyle(
							showCommunity
								? Color.kkAccent
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
						ForEach(mergedKeyframelessItems) { item in
							switch item {
							case .installed(let template):
								CaptionTemplateCard(
									template: template,
									isSelected: template.id == model.selectedTemplate.id,
									isFavorite: favorites.contains(template.id),
									onSelect: { model.selectedTemplate = template },
									onToggleFavorite: { favorites.toggle(template.id) }
								)
								.id(template.id)
							case .community(let template):
								CommunityTemplateCard(
									template: template,
									onDownload: { downloadCommunityTemplate(template) }
								)
							}
						}
						if communityStore.isLoading {
							HStack {
								Spacer()
								ProgressView()
									.controlSize(.small)
								Text("Loading community templates...")
									.font(.system(size: 10))
									.foregroundStyle(.secondary)
								Spacer()
							}
							.padding(.vertical, KKPaddingLG)
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
		.onAppear { communityStore.fetchIfNeeded() }
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			handleDrop(providers)
		}
	}

	private func downloadCommunityTemplate(_ template: CommunityTemplate) {
		Task {
			do {
				try await CommunityTemplateStore.download(template)
				await MainActor.run { model.refreshTemplates() }
			} catch {
				print("Download failed: \(error.localizedDescription)")
			}
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
		if let url = template.resolvedMotiURL() {
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

}
