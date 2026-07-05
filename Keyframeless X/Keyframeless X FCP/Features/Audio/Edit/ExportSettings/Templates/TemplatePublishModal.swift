/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

struct TemplatePublishModal: View {
	let template: CaptionTemplate
	let params: [PublishedParameter]
	let hasPerWordAnimation: Bool
	let onDismiss: () -> Void

	@State private var name: String
	@State private var author: String = ""
	@State private var previewGifURL: URL?
	@State private var isDropTargeted = false
	@State private var gifTooLarge = false
	@State private var gifWrongAspect = false
	@State private var focusName = false
	@State private var focusAuthor = false
	@State private var isPublishing = false
	@State private var publishError: String?

	init(
		template: CaptionTemplate,
		params: [PublishedParameter],
		hasPerWordAnimation: Bool,
		onDismiss: @escaping () -> Void
	) {
		self.template = template
		self.params = params
		self.hasPerWordAnimation = hasPerWordAnimation
		self.onDismiss = onDismiss
		_name = State(initialValue: template.name)
	}

	private var canPublish: Bool {
		!name.trimmingCharacters(in: .whitespaces).isEmpty && previewGifURL != nil && !gifTooLarge
			&& !gifWrongAspect
	}

	private var enabledParams: [PublishedParameter] {
		params.filter(\.isToggleable)
	}

	var body: some View {
		ModalContainer(width: 360, onDismiss: onDismiss) {
			HStack {
				Text("Publish Template")
					.font(.title3)
					.foregroundStyle(.primary)
				Spacer()
				if hasPerWordAnimation {
					InfoBadge(
						label: String(localized: "Per word"), systemImage: "directcurrent",
						color: .green)
				}
			}

			VStack(alignment: .leading, spacing: KKSpacingLG) {
				LabeledField(label: String(localized: "Name")) {
					HStack(spacing: KKSpacingSM) {
						Image(systemName: "tag.fill")
							.font(.system(size: 10))
							.foregroundStyle(.secondary)
						PublishTextField(
							text: $name, placeholder: String(localized: "Template name"),
							requestFocus: $focusName
						)
						.frame(height: 16)
					}
					.padding(.horizontal, KKPaddingLG)
					.padding(.vertical, KKPaddingLG)
					.contentShape(Rectangle())
					.onTapGesture { focusName.toggle() }
					.kkPanel(cornerRadius: KKRadiusMD)
				}
				LabeledField(label: String(localized: "Author")) {
					HStack(spacing: KKSpacingSM) {
						Image(systemName: "person.circle.fill")
							.font(.system(size: 10))
							.foregroundStyle(.secondary)
						PublishTextField(
							text: $author, placeholder: String(localized: "Optional"),
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
			}

			VStack(alignment: .leading, spacing: KKSpacingSM) {
				HStack {
					Text("Preview")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
					Spacer()
					Text("16:9 Aspect Ratio - Max size 300Kb")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Button {
					downloadSampleAudio()
				} label: {
					HStack(spacing: KKSpacingSM) {
						Image(systemName: "arrow.down.circle.fill")
							.font(.system(size: 10))
						Text("Download Sample Audio")
							.font(.system(size: 11))
					}
					.foregroundStyle(Color.kkAccent)
				}
				.buttonStyle(.plain)
				GifDropZone(
					gifURL: previewGifURL,
					isDropTargeted: $isDropTargeted,
					onPick: { FilePicker.pickGif { setGif($0) } },
					onDrop: { FilePicker.handleDrop($0, extension: "gif") { setGif($0) } }
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

			if !enabledParams.isEmpty {
				VStack(alignment: .leading, spacing: KKSpacingSM) {
					Text("Parameters")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
					HStack(spacing: KKSpacingSM) {
						ForEach(enabledParams) { param in
							paramBadge(param)
						}
					}
				}
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
				Button(isPublishing ? "Publishing..." : "Publish") { publish() }
					.buttonStyle(.plain)
					.foregroundStyle(
						canPublish && !isPublishing
							? Color.kkAccent : .secondary.opacity(0.4)
					)
					.disabled(!canPublish || isPublishing)
			}
		}
	}

	@ViewBuilder
	private func paramBadge(_ param: PublishedParameter) -> some View {
		InfoBadge(
			label: param.name,
			systemImage: param.kind.displayIcon,
			color: param.kind.displayColor)
	}

	private func setGif(_ url: URL) {
		let result = GifValidator.validate(url)
		gifTooLarge = result.isTooLarge
		gifWrongAspect = result.isWrongAspect
		previewGifURL = url
	}

	private func downloadSampleAudio() {
		guard
			let sourceURL = Bundle.main.url(
				forResource: "the-quick-brown-fox-jumps-over-the-lazy-dog",
				withExtension: "m4a"
			)
		else { return }
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "the-quick-brown-fox-jumps-over-the-lazy-dog.m4a"
		panel.allowedContentTypes = [UTType.mpeg4Audio]
		guard panel.runModal() == .OK, let destURL = panel.url else { return }
		try? FileManager.default.copyItem(at: sourceURL, to: destURL)
	}

	private func publish() {
		guard canPublish, !isPublishing else { return }
		guard let motiDir = template.resolvedMotiURL()?.deletingLastPathComponent() else {
			publishError = "Could not locate template directory"
			return
		}
		guard let gifURL = previewGifURL else { return }

		isPublishing = true
		publishError = nil

		let perWordStartsAtZero =
			TemplatePublishedParamsStore.shared.params(for: template.id)?.perWordStartsAtZero
			?? false
		let payload = CommunityPublisher.TemplatePayload(
			id: UUID().uuidString,
			name: name.trimmingCharacters(in: .whitespaces),
			author: author.trimmingCharacters(in: .whitespaces),
			perWord: hasPerWordAnimation,
			perWordStartsAtZero: perWordStartsAtZero,
			params: enabledParams.map { ["name": $0.name, "kind": "\($0.kind)"] },
			version: 1,
			motiDirectoryURL: motiDir,
			previewGifURL: gifURL
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
