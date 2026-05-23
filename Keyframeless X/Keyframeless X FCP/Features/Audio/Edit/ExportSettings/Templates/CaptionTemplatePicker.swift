/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
	@State private var downloadError: String?

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
			result = result.filter {
				$0.name.localizedCaseInsensitiveContains(searchText)
					|| ($0.author?.localizedCaseInsensitiveContains(searchText) ?? false)
			}
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
			result = result.filter {
				$0.name.localizedCaseInsensitiveContains(searchText)
					|| $0.author.localizedCaseInsensitiveContains(searchText)
			}
		}
		return result
	}

	private var mergedKeyframelessItems: [KeyframelessItem] {
		let installed = keyframelessTemplates.map { KeyframelessItem.installed($0) }
		let community =
			showCommunity && !showFavoritesOnly
			? filteredCommunityTemplates.map { KeyframelessItem.community($0) } : []
		return (installed + community).sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
	}

	private var hasEnabledControls: Bool {
		guard let settings = paramsStore.params(for: model.selectedTemplate.id) else {
			return false
		}
		return settings.allParams.contains(where: \.isToggleable)
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
				Button {
					communityStore.fetch()
					model.refreshTemplates()
				} label: {
					Image(systemName: "arrow.clockwise")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.frame(maxHeight: .infinity)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				Spacer()
				if let downloadError {
					HStack(spacing: 4) {
						Image(systemName: "exclamationmark.triangle.fill")
						Text(downloadError)
					}
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(Color.kkError)
				}
				if communityStore.needsFCPRestart {
					HStack(spacing: 4) {
						Image(systemName: "arrow.trianglehead.2.counterclockwise")
						Text("Restart FCP")
					}
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(Color.kkAccent)
				}
			}
			.fixedSize(horizontal: false, vertical: true)
			HStack(spacing: KKSpacingLG) {
				ScrollShadowView(cornerRadius: KKRadiusSM, scrollToID: model.selectedTemplate.id) {
					VStack(alignment: .leading, spacing: KKSpacingLG) {
						TemplateSection(title: "Keyframeless") {
							ForEach(mergedKeyframelessItems) { item in
								switch item {
								case .installed(let template):
									let community = communityStore.templates.first {
										$0.name == template.name
									}
									CaptionTemplateCard(
										template: template,
										isSelected: template.id == model.selectedTemplate.id,
										isFavorite: favorites.contains(template.id),
										onSelect: { model.selectedTemplate = template },
										onToggleFavorite: { favorites.toggle(template.id) },
										onUpdate: community.map { c in
											{ showUpdateModal(for: c) }
										}
									)
									.id(template.id)
								case .community(let community):
									CommunityTemplateCard(
										template: community,
										isInstalled: templates.contains {
											$0.name == community.name
										},
										onDownload: { downloadCommunityTemplate(community) },
										onUpdate: { showUpdateModal(for: community) }
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
						TemplateSection(title: String(localized: "Custom")) {
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
				TemplateParamsPanel(
					template: model.selectedTemplate,
					store: paramsStore
				)
				.frame(width: 200)
			}
		}
		.onAppear { communityStore.fetch() }
		.onChange(of: communityStore.templates.map(\.id)) {
			reconcileCommunityParams()
		}
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			handleDrop(providers)
		}
	}

	private func downloadCommunityTemplate(_ template: CommunityTemplate) {
		downloadError = nil
		Task {
			do {
				try await CommunityTemplateStore.download(template)
				await MainActor.run { model.refreshTemplates() }
			} catch let error as CocoaError where error.code == .fileWriteNoPermission {
				await MainActor.run {
					downloadError =
						"Permission denied. Run: sudo chown $USER ~/Movies/Motion\\ Templates.localized"
				}
			} catch {
				await MainActor.run {
					downloadError = error.localizedDescription
				}
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
		let templateID = "custom:\(url.path)"
		if let added = model.captionTemplates.first(where: { $0.id == templateID }) {
			// Store text ozml even if no published params
			if let textOzml = result.textOzml {
				paramsStore.setTextOzml(textOzml, for: templateID)
			}
			guard !result.customParams.isEmpty || result.hasPerWordAnimation else { return }
			model.paramsModalParams = result.customParams
			model.paramsModalHasPerWord = result.hasPerWordAnimation
			model.paramsModalTemplate = added
		}
	}

	private func showParamsModal(for template: CaptionTemplate) {
		let existing = paramsStore.params(for: template.id)
		if let url = template.resolvedMotiURL() {
			let result = PublishedParameter.parseAll(from: url)
			model.paramsModalParams = result.customParams
			model.paramsModalHasPerWord = result.hasPerWordAnimation
			if let textOzml = result.textOzml {
				paramsStore.setTextOzml(textOzml, for: template.id)
			}
		} else if let existing {
			model.paramsModalParams = existing.allParams
			model.paramsModalHasPerWord = existing.hasPerWordAnimation
		} else {
			model.paramsModalParams = []
			model.paramsModalHasPerWord = false
		}
		model.paramsModalTemplate = template
	}

	private func showUpdateModal(for community: CommunityTemplate) {
		let local = templates.first { $0.name == community.name }
		let template =
			local
			?? CaptionTemplate(
				id: community.id, name: community.name, uid: "",
				supportsPerWordAnimation: community.perWord,
				wordsInParamName: nil, wordsInKeyPath: nil,
				isBuiltIn: false, isCustom: false)
		model.updateModalTemplate = (template, community)
	}

	private func reconcileCommunityParams() {
		let communityByName = Dictionary(
			communityStore.templates.map { ($0.name, $0) },
			uniquingKeysWith: { first, _ in first }
		)
		for template in keyframelessTemplates where !template.isBuiltIn {
			guard let community = communityByName[template.name] else { continue }

			if community.perWord {
				paramsStore.setPerWordStartsAtZero(
					community.perWordStartsAtZero, for: template.id)
			}

			guard paramsStore.params(for: template.id)?.allParams.isEmpty ?? true,
				let motiURL = template.resolvedMotiURL()
			else { continue }
			let result = PublishedParameter.parseAll(from: motiURL)
			guard !community.params.isEmpty || result.hasPerWordAnimation else { continue }
			let kindsByName = Dictionary(
				community.params.compactMap { dict -> (String, String)? in
					guard let name = dict["name"], let kind = dict["kind"] else { return nil }
					return (name, kind)
				},
				uniquingKeysWith: { _, last in last }
			)
			let configured = result.customParams.map { param -> PublishedParameter in
				var p = param
				if let kindRaw = kindsByName[p.name],
					let kind = PublishedParameter.ParamKind(rawValue: kindRaw)
				{
					p.kind = kind
				}
				return p
			}
			paramsStore.setParams(
				configured, hasPerWordAnimation: result.hasPerWordAnimation,
				textOzml: result.textOzml, for: template.id)
		}
	}

}
