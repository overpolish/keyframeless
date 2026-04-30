/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

struct TemplateUpdateModal: View {
	let template: CaptionTemplate
	let communityTemplate: CommunityTemplate
	let params: [PublishedParameter]
	let hasPerWordAnimation: Bool
	let onDismiss: () -> Void

	@State private var author: String
	@State private var newMotiURL: URL?
	@State private var newPreviewGifURL: URL?
	@State private var isDropTargetedMoti = false
	@State private var isDropTargetedGif = false
	@State private var gifTooLarge = false
	@State private var gifWrongAspect = false
	@State private var focusAuthor = false
	@State private var isPublishing = false
	@State private var publishError: String?
	@State private var paramKinds: [String: PublishedParameter.ParamKind]
	@State private var fontModes: [String: TemplatePublishedParamsStore.FontMode]
	@State private var perWordStartsAtZero: Bool

	private var currentVersion: Int { communityTemplate.version }
	private var nextVersion: Int { currentVersion + 1 }

	init(
		template: CaptionTemplate,
		communityTemplate: CommunityTemplate,
		params: [PublishedParameter],
		hasPerWordAnimation: Bool,
		onDismiss: @escaping () -> Void
	) {
		self.template = template
		self.communityTemplate = communityTemplate
		self.params = params
		self.hasPerWordAnimation = hasPerWordAnimation
		self.onDismiss = onDismiss
		_author = State(initialValue: communityTemplate.author)

		let kindsByName = Self.kindsByName(from: communityTemplate)
		_paramKinds = State(
			initialValue: Dictionary(
				uniqueKeysWithValues: params.filter { $0.defaultFont == nil }.map { p in
					let kind =
						kindsByName[p.name].flatMap {
							PublishedParameter.ParamKind(rawValue: $0)
						} ?? .off
					return (p.id, kind)
				}))
		_fontModes = State(
			initialValue: Dictionary(
				uniqueKeysWithValues: params.filter { $0.defaultFont != nil }.map { p in
					let isFont = kindsByName[p.name] == "font"
					return (p.id, isFont ? TemplatePublishedParamsStore.FontMode.custom : .base)
				}))
		_perWordStartsAtZero = State(initialValue: communityTemplate.perWordStartsAtZero)
	}

	private static func kindsByName(from community: CommunityTemplate) -> [String: String] {
		Dictionary(
			community.params.compactMap { dict -> (String, String)? in
				guard let name = dict["name"], let kind = dict["kind"] else { return nil }
				return (name, kind)
			},
			uniquingKeysWith: { _, last in last })
	}

	private var canPublish: Bool {
		(newMotiURL != nil || newPreviewGifURL != nil || paramsChanged)
			&& !gifTooLarge && !gifWrongAspect
	}

	private var paramsChanged: Bool {
		let kinds = Self.kindsByName(from: communityTemplate)
		for param in nonFontParams {
			let old =
				kinds[param.name].flatMap { PublishedParameter.ParamKind(rawValue: $0) } ?? .off
			if paramKinds[param.id] != old { return true }
		}
		for param in fontParams {
			if (kinds[param.name] == "font") != (fontModes[param.id] == .custom) { return true }
		}
		return false
	}

	private var fontParams: [PublishedParameter] { params.filter { $0.defaultFont != nil } }
	private var nonFontParams: [PublishedParameter] { params.filter { $0.defaultFont == nil } }

	private var resolvedParams: [[String: String]] {
		var result: [[String: String]] = []
		for p in nonFontParams {
			let kind = paramKinds[p.id] ?? .off
			guard kind != .off else { continue }
			result.append(["name": p.name, "kind": "\(kind)"])
		}
		for p in fontParams where fontModes[p.id] == .custom {
			result.append(["name": p.name, "kind": "font"])
		}
		return result
	}

	var body: some View {
		ModalContainer(width: 620, onDismiss: onDismiss) {
			header
			HStack(alignment: .top, spacing: KKSpacingXL) {
				leftColumn.frame(width: 260)
				rightColumn
			}
			errorAndButtons
		}
	}

	private var header: some View {
		HStack {
			Text("Update Template").font(.title3).foregroundStyle(.primary)
			Spacer()
			if hasPerWordAnimation {
				InfoBadge(label: "Per word", systemImage: "directcurrent", color: .green)
			}
			HStack(spacing: KKSpacingMD) {
				Text("v\(currentVersion)").font(.system(size: 11)).foregroundStyle(.secondary)
				Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
				Text("v\(nextVersion)").font(.system(size: 11, weight: .medium))
					.foregroundStyle(Color.kkAccent)
			}
		}
	}

	private var leftColumn: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			LabeledField(label: "Name") {
				HStack(spacing: KKSpacingSM) {
					Image(systemName: "tag.fill").font(.system(size: 10)).foregroundStyle(
						.secondary)
					Text(communityTemplate.name).font(.system(size: 11)).foregroundStyle(.secondary)
				}
				.padding(.horizontal, KKPaddingLG).padding(.vertical, KKPaddingLG)
				.frame(maxWidth: .infinity, alignment: .leading)
				.kkPanel(cornerRadius: KKRadiusMD)
			}
			LabeledField(label: "Author") {
				HStack(spacing: KKSpacingSM) {
					Image(systemName: "person.circle.fill").font(.system(size: 10))
						.foregroundStyle(.secondary)
					PublishTextField(
						text: $author, placeholder: "Optional", requestFocus: $focusAuthor
					)
					.frame(height: 16)
				}
				.padding(.horizontal, KKPaddingLG).padding(.vertical, KKPaddingLG)
				.contentShape(Rectangle()).onTapGesture { focusAuthor.toggle() }
				.kkPanel(cornerRadius: KKRadiusMD)
			}
			motiSection
			gifSection
		}
	}

	private var motiSection: some View {
		VStack(alignment: .leading, spacing: KKSpacingSM) {
			HStack {
				Text(".moti").font(.system(size: 11)).foregroundStyle(.secondary)
				Spacer()
				if let url = newMotiURL {
					Text(url.lastPathComponent).font(.system(size: 10)).foregroundStyle(
						Color.kkAccent)
				} else {
					Text("Keep current").font(.system(size: 10))
						.foregroundStyle(.secondary.opacity(0.6))
				}
			}
			MotiUpdateDropZone(
				hasNewMoti: newMotiURL != nil,
				isDropTargeted: $isDropTargetedMoti,
				onPick: { FilePicker.pickMoti { newMotiURL = $0 } },
				onDrop: { FilePicker.handleDrop($0, extension: "moti") { newMotiURL = $0 } }
			)
		}
	}

	private var gifSection: some View {
		VStack(alignment: .leading, spacing: KKSpacingSM) {
			HStack {
				Text("Preview").font(.system(size: 11)).foregroundStyle(.secondary)
				Spacer()
				Text("16:9 - Max 300Kb").font(.caption).foregroundStyle(.secondary)
			}
			GifDropZone(
				gifURL: newPreviewGifURL ?? communityTemplate.previewGifURL,
				isDropTargeted: $isDropTargetedGif,
				onPick: { FilePicker.pickGif { setGif($0) } },
				onDrop: { FilePicker.handleDrop($0, extension: "gif") { setGif($0) } }
			)
			if gifTooLarge {
				Text("GIF exceeds 300 KB limit").font(.system(size: 10)).foregroundStyle(
					Color.kkError)
			}
			if gifWrongAspect {
				Text("GIF must be 16:9 aspect ratio").font(.system(size: 10))
					.foregroundStyle(Color.kkError)
			}
		}
	}

	private var rightColumn: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			Text("Parameters").font(.system(size: 11)).foregroundStyle(.secondary)
			if hasPerWordAnimation {
				HStack(spacing: KKSpacingSM) {
					Text("Word Timing").font(.caption).foregroundStyle(.primary)
					Spacer()
					PillToggle(
						selection: $perWordStartsAtZero,
						options: [
							(label: "Straight Away", value: true),
							(label: "Late Start", value: false),
						])
				}
			}
			if !params.isEmpty {
				ScrollShadowView {
					VStack(spacing: KKSpacingMD) {
						ForEach(fontParams) { param in
							FontModeRow(
								name: param.name,
								fontMode: Binding(
									get: { fontModes[param.id] ?? .base },
									set: { fontModes[param.id] = $0 }))
						}
						ForEach(nonFontParams) { param in
							ParamKindRow(
								name: param.name,
								kind: Binding(
									get: { paramKinds[param.id] ?? .off },
									set: { paramKinds[param.id] = $0 }))
						}
					}
					.frame(maxWidth: .infinity)
				}
				.frame(maxHeight: 300)
			} else if !hasPerWordAnimation {
				Spacer()
				Text("No published parameters")
					.font(.system(size: 10)).foregroundStyle(.secondary.opacity(0.6))
					.frame(maxWidth: .infinity)
				Spacer()
			}
		}
	}

	@ViewBuilder
	private var errorAndButtons: some View {
		if let publishError {
			Text(publishError).font(.system(size: 10)).foregroundStyle(Color.kkError)
				.fixedSize(horizontal: false, vertical: true)
		}
		HStack {
			Button("Cancel") { onDismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
			Spacer()
			Button(isPublishing ? "Updating..." : "Update") { update() }
				.buttonStyle(.plain)
				.foregroundStyle(
					canPublish && !isPublishing ? Color.kkAccent : .secondary.opacity(0.4)
				)
				.disabled(!canPublish || isPublishing)
		}
	}

	private func setGif(_ url: URL) {
		let result = GifValidator.validate(url)
		gifTooLarge = result.isTooLarge
		gifWrongAspect = result.isWrongAspect
		newPreviewGifURL = url
	}

	private func update() {
		guard canPublish, !isPublishing else { return }
		isPublishing = true
		publishError = nil

		let motiDir = newMotiURL?.deletingLastPathComponent()
		let payload = CommunityPublisher.TemplatePayload(
			id: communityTemplate.id,
			name: communityTemplate.name,
			author: author.trimmingCharacters(in: .whitespaces),
			perWord: hasPerWordAnimation,
			perWordStartsAtZero: perWordStartsAtZero,
			params: resolvedParams,
			version: nextVersion,
			motiDirectoryURL: motiDir,
			previewGifURL: newPreviewGifURL
		)

		Task {
			do {
				try await CommunityPublisher.publish(payload)
				await MainActor.run {
					isPublishing = false
					onDismiss()
				}
			} catch {
				await MainActor.run {
					isPublishing = false
					publishError = error.localizedDescription
				}
			}
		}
	}
}

private struct MotiUpdateDropZone: View {
	let hasNewMoti: Bool
	@Binding var isDropTargeted: Bool
	let onPick: () -> Void
	let onDrop: ([NSItemProvider]) -> Bool

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: KKRadiusMD).fill(Color.white.opacity(0.06))
			if hasNewMoti {
				Image(systemName: "checkmark.circle.fill")
					.font(.system(size: 16)).foregroundStyle(Color.kkAccent)
			} else {
				VStack(spacing: KKSpacingSM) {
					Image(systemName: "doc.badge.plus")
						.font(.system(size: 16)).foregroundStyle(.secondary.opacity(0.5))
					Text("Drop new .moti")
						.font(.system(size: 10)).foregroundStyle(.secondary.opacity(0.5))
				}
			}
			if isDropTargeted {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(Color.kkAccent, lineWidth: KKBorderWidthSM)
			}
		}
		.frame(height: 60)
		.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
		.overlay(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.strokeBorder(
					Color.secondary.opacity(0.2),
					style: hasNewMoti
						? StrokeStyle(lineWidth: KKBorderWidthXS)
						: StrokeStyle(lineWidth: KKBorderWidthXS, dash: [4, 3]))
		)
		.contentShape(Rectangle())
		.onTapGesture { onPick() }
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { onDrop($0) }
	}
}
