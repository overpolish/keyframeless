/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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

		// Pre-fill param kinds from community metadata
		let kindsByName = Dictionary(
			communityTemplate.params.compactMap { dict -> (String, String)? in
				guard let name = dict["name"], let kind = dict["kind"] else { return nil }
				return (name, kind)
			},
			uniquingKeysWith: { _, last in last }
		)
		_paramKinds = State(
			initialValue: Dictionary(
				uniqueKeysWithValues: params.filter { $0.defaultFont == nil }.map { p in
					let kind = kindsByName[p.name].flatMap {
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

	private var canPublish: Bool {
		(newMotiURL != nil || newPreviewGifURL != nil || paramsChanged)
			&& !gifTooLarge && !gifWrongAspect
	}

	private var paramsChanged: Bool {
		let kindsByName = Dictionary(
			communityTemplate.params.compactMap { dict -> (String, String)? in
				guard let name = dict["name"], let kind = dict["kind"] else { return nil }
				return (name, kind)
			},
			uniquingKeysWith: { _, last in last }
		)
		for param in nonFontParams {
			let oldKind = kindsByName[param.name].flatMap {
				PublishedParameter.ParamKind(rawValue: $0)
			} ?? .off
			if paramKinds[param.id] != oldKind { return true }
		}
		for param in fontParams {
			let wasFont = kindsByName[param.name] == "font"
			let isFont = fontModes[param.id] == .custom
			if wasFont != isFont { return true }
		}
		return false
	}

	private var fontParams: [PublishedParameter] {
		params.filter { $0.defaultFont != nil }
	}

	private var nonFontParams: [PublishedParameter] {
		params.filter { $0.defaultFont == nil }
	}

	private var resolvedParams: [[String: String]] {
		var result: [[String: String]] = []
		for param in nonFontParams {
			let kind = paramKinds[param.id] ?? .off
			guard kind != .off else { continue }
			result.append(["name": param.name, "kind": "\(kind)"])
		}
		for param in fontParams {
			if fontModes[param.id] == .custom {
				result.append(["name": param.name, "kind": "font"])
			}
		}
		return result
	}

	var body: some View {
		ZStack {
			Color.black.opacity(0.5)
				.ignoresSafeArea()
				.onTapGesture { onDismiss() }
			VStack(alignment: .leading, spacing: KKSpacingXL) {
				HStack {
					Text("Update Template")
						.font(.title3)
						.foregroundStyle(.primary)
					Spacer()
					HStack(spacing: KKSpacingMD) {
						Text("v\(currentVersion)")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
						Image(systemName: "arrow.right")
							.font(.system(size: 9))
							.foregroundStyle(.secondary)
						Text("v\(nextVersion)")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Color.kkAccent)
					}
					if hasPerWordAnimation {
						InfoBadge(
							label: "Per word",
							systemImage: "directcurrent",
							color: .green
						)
					}
				}

				HStack(alignment: .top, spacing: KKSpacingXL) {
					VStack(alignment: .leading, spacing: KKSpacingLG) {
						LabeledField(label: "Name") {
							HStack(spacing: KKSpacingSM) {
								Image(systemName: "tag.fill")
									.font(.system(size: 10))
									.foregroundStyle(.secondary)
								Text(communityTemplate.name)
									.font(.system(size: 11))
									.foregroundStyle(.secondary)
							}
							.padding(.horizontal, KKPaddingLG)
							.padding(.vertical, KKPaddingLG)
							.frame(maxWidth: .infinity, alignment: .leading)
							.kkPanel(cornerRadius: KKRadiusMD)
						}
						LabeledField(label: "Author") {
							HStack(spacing: KKSpacingSM) {
								Image(systemName: "person.circle.fill")
									.font(.system(size: 10))
									.foregroundStyle(.secondary)
								PublishTextField(
									text: $author, placeholder: "Optional",
									requestFocus: $focusAuthor
								)
								.frame(height: 16)
							}
							.padding(.horizontal, KKPaddingLG)
							.padding(.vertical, KKPaddingLG)
							.contentShape(Rectangle())
							.onTapGesture { focusAuthor.toggle() }
							.kkPanel(cornerRadius: KKRadiusMD)
						}

						VStack(alignment: .leading, spacing: KKSpacingSM) {
							HStack {
								Text(".moti")
									.font(.system(size: 11))
									.foregroundStyle(.secondary)
								Spacer()
								if newMotiURL != nil {
									Text(newMotiURL!.lastPathComponent)
										.font(.system(size: 10))
										.foregroundStyle(Color.kkAccent)
								} else {
									Text("Keep current")
										.font(.system(size: 10))
										.foregroundStyle(.secondary.opacity(0.6))
								}
							}
							MotiUpdateDropZone(
								hasNewMoti: newMotiURL != nil,
								isDropTargeted: $isDropTargetedMoti,
								onPick: pickMoti,
								onDrop: handleMotiDrop
							)
						}

						VStack(alignment: .leading, spacing: KKSpacingSM) {
							HStack {
								Text("Preview")
									.font(.system(size: 11))
									.foregroundStyle(.secondary)
								Spacer()
								Text("16:9 - Max 300Kb")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							GifDropZone(
								gifURL: newPreviewGifURL ?? communityTemplate.previewGifURL,
								isDropTargeted: $isDropTargetedGif,
								onPick: pickGif,
								onDrop: handleGifDrop
							)
							if gifTooLarge {
								Text("GIF exceeds 300 KB limit")
									.font(.system(size: 10))
									.foregroundStyle(Color.kkError)
							}
							if gifWrongAspect {
								Text("GIF must be 16:9 aspect ratio")
									.font(.system(size: 10))
									.foregroundStyle(Color.kkError)
							}
						}
					}
					.frame(width: 260)

					VStack(alignment: .leading, spacing: KKSpacingLG) {
						Text("Parameters")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
						if hasPerWordAnimation {
							HStack(alignment: .center, spacing: KKSpacingSM) {
								Text("Word Timing")
									.font(.caption)
									.foregroundStyle(.primary)
								Spacer()
								PillToggle(
									selection: $perWordStartsAtZero,
									options: [
										(label: "Straight Away", value: true),
										(label: "Late Start", value: false),
									]
								)
							}
						}
						if !params.isEmpty {
							ScrollShadowView {
								VStack(spacing: KKSpacingMD) {
									ForEach(fontParams) { param in
										UpdateFontModeRow(
											name: param.name,
											fontMode: Binding(
												get: { fontModes[param.id] ?? .base },
												set: { fontModes[param.id] = $0 }
											)
										)
									}
									ForEach(nonFontParams) { param in
										UpdateParamKindRow(
											name: param.name,
											kind: Binding(
												get: { paramKinds[param.id] ?? .off },
												set: { paramKinds[param.id] = $0 }
											)
										)
									}
								}
							}
							.frame(maxHeight: 300)
						} else if !hasPerWordAnimation {
							Text("No published parameters")
								.font(.system(size: 10))
								.foregroundStyle(.secondary.opacity(0.6))
						}
					}
					.frame(width: 300)
				}

				if let publishError {
					Text(publishError)
						.font(.system(size: 10))
						.foregroundStyle(Color.kkError)
						.fixedSize(horizontal: false, vertical: true)
				}

				HStack {
					Button("Cancel") { onDismiss() }
						.buttonStyle(.plain)
						.foregroundStyle(.secondary)
					Spacer()
					Button(isPublishing ? "Updating..." : "Update") { update() }
						.buttonStyle(.plain)
						.foregroundStyle(
							canPublish && !isPublishing
								? Color.kkAccent : .secondary.opacity(0.4)
						)
						.disabled(!canPublish || isPublishing)
				}
			}
			.padding(KKPaddingXL)
			.frame(width: 620)
			.kkPanel()
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.fill(Color(nsColor: .windowBackgroundColor))
			)
		}
	}


	private static let maxGifSize = 300 * 1024

	private func setGif(_ url: URL) {
		let size =
			(try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
		gifTooLarge = size > Self.maxGifSize
		if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let w = props[kCGImagePropertyPixelWidth] as? Int,
			let h = props[kCGImagePropertyPixelHeight] as? Int, h > 0
		{
			let ratio = Double(w) / Double(h)
			gifWrongAspect = abs(ratio - 16.0 / 9.0) > 0.05
		} else {
			gifWrongAspect = true
		}
		newPreviewGifURL = url
	}

	private func pickGif() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType.gif]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		setGif(url)
	}

	private func handleGifDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
				guard let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					url.pathExtension.lowercased() == "gif"
				else { return }
				DispatchQueue.main.async { setGif(url) }
			}
		}
		return true
	}

	private func pickMoti() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "moti") ?? .data]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		newMotiURL = url
	}

	private func handleMotiDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
				guard let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					url.pathExtension.lowercased() == "moti"
				else { return }
				DispatchQueue.main.async { newMotiURL = url }
			}
		}
		return true
	}

	private func update() {
		guard canPublish, !isPublishing else { return }

		let motiDir: URL?
		if let motiURL = newMotiURL {
			motiDir = motiURL.deletingLastPathComponent()
		} else {
			motiDir = nil
		}

		isPublishing = true
		publishError = nil

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
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(Color.white.opacity(0.06))
			if hasNewMoti {
				Image(systemName: "checkmark.circle.fill")
					.font(.system(size: 16))
					.foregroundStyle(Color.kkAccent)
			} else {
				VStack(spacing: KKSpacingSM) {
					Image(systemName: "doc.badge.plus")
						.font(.system(size: 16))
						.foregroundStyle(.secondary.opacity(0.5))
					Text("Drop new .moti")
						.font(.system(size: 10))
						.foregroundStyle(.secondary.opacity(0.5))
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
						: StrokeStyle(lineWidth: KKBorderWidthXS, dash: [4, 3])
				)
		)
		.contentShape(Rectangle())
		.onTapGesture { onPick() }
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			onDrop(providers)
		}
	}
}

private struct UpdateParamKindRow: View {
	let name: String
	@Binding var kind: PublishedParameter.ParamKind

	private let kindOptions:
		[(label: String, value: PublishedParameter.ParamKind, icon: String?, color: Color?)] = [
			("Off", .off, nil, .kkError),
			("Color", .color, "paintpalette", .kkAccent),
			("Slider", .slider, "slider.horizontal.3", .kkWarning),
			("Toggle", .toggle, "checkmark.circle", .green),
		]

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Text(name)
				.font(.system(size: 11))
				.foregroundStyle(.primary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
			Spacer()
			PillToggle(selection: $kind, options: kindOptions)
				.fixedSize()
		}
		.padding(.vertical, KKPaddingXS)
	}
}

private struct UpdateFontModeRow: View {
	let name: String
	@Binding var fontMode: TemplatePublishedParamsStore.FontMode

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Image(systemName: "textformat")
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
			Text(name)
				.font(.system(size: 11))
				.foregroundStyle(.primary)
			Spacer()
			PillToggle(
				selection: $fontMode,
				options: [
					(label: "Base", value: TemplatePublishedParamsStore.FontMode.base),
					(label: "Custom", value: TemplatePublishedParamsStore.FontMode.custom),
				]
			)
		}
		.padding(.vertical, KKPaddingXS)
	}
}
