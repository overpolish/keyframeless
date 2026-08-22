/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

/// What Sonar has published, and what Mirage's audio dropdown will offer.
///
/// Publishing writes a file and nothing else moves, so without this the button
/// is the only evidence anything happened - and there'd be no way to see what
/// you published last week, or get rid of it.
struct SonarSourcesList: View {
	let sources: [SonarSource]
	var onRename: (SonarSource, String) -> Void
	var onDelete: (SonarSource) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingSM) {
			HStack {
				Text("Published Sources")
					.font(.title3)
					.foregroundStyle(.secondary)
				Spacer()
			}
			Group {
				if sources.isEmpty {
					HelperText(
						String(
							localized:
								"Nothing published yet - Publish makes the selected audio available to Keyframeless plugins"
						),
						systemImage: "waveform"
					)
					.padding(KKPaddingMD)
					.frame(maxWidth: .infinity, alignment: .leading)
				} else {
					ScrollShadowView {
						LazyVStack(alignment: .leading, spacing: 0) {
							ForEach(sources) { source in
								SonarSourceRow(
									source: source,
									onRename: { onRename(source, $0) },
									onDelete: { onDelete(source) }
								)
							}
						}
						.padding(KKPaddingMD)
					}
					// `fixedSize` vertically is what stops the scroll view collapsing:
					// it has no intrinsic height, so against the timeline's greedy
					// `.infinity` frame it otherwise negotiates down to zero and the
					// rows vanish, leaving a bare header. Same idiom as Steno's
					// untranscribed box.
					.frame(maxHeight: 100, alignment: .top)
					.fixedSize(horizontal: false, vertical: true)
				}
			}
			.kkPanel()
			// Users hoard sources out of caution, so the safety net has to be
			// said out loud: the ticket in the plugin's own parameters is what
			// makes deletion recoverable, and nothing else in the UI hints at it.
			if !sources.isEmpty {
				HelperText(
					String(
						localized:
							"Deleting is safe - plugins remember which clips a source used, and Sonar reselects them when you drop the project again"
					),
					systemImage: "arrow.uturn.backward"
				)
			}
		}
	}
}

private struct SonarSourceRow: View {
	let source: SonarSource
	var onRename: (String) -> Void
	var onDelete: () -> Void

	@State private var isHovering = false
	@State private var isEditing = false
	@State private var draft = ""
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			if isEditing {
				TextField("", text: $draft)
					.textFieldStyle(.plain)
					.font(.system(size: 12, weight: .semibold))
					.focused($focused)
					.frame(maxWidth: 160)
					.onSubmit { commit() }
					// Escape abandons the edit; without this the only way out of the
					// field is to commit something.
					.onExitCommand { isEditing = false }
			} else {
				Text(source.name)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(.secondary)
			}
			Spacer()
			if isHovering, !isEditing {
				HStack(spacing: KKSpacingLG) {
					Button {
						draft = source.name
						isEditing = true
						focused = true
					} label: {
						Text("Rename")
							.font(.system(size: 11))
					}
					.buttonStyle(.plain)
					.foregroundStyle(Color.kkAccent)
					Button(action: onDelete) {
						Text("Delete")
							.font(.system(size: 11))
					}
					.buttonStyle(.plain)
					.foregroundStyle(Color.kkWarning)
				}
				// Keeps the actions from crowding the badges they sit next to.
				.padding(.trailing, KKSpacingMD)
			}
			Text(age)
				.font(.system(size: 11))
				.foregroundStyle(.tertiary)
			InfoBadge(
				label: String(localized: "\(source.clipCount) clips"),
				systemImage: "waveform")
			if let project = source.projectName {
				InfoBadge(label: project, systemImage: "film")
			}
		}
		.padding(.vertical, KKPaddingSM)
		.padding(.horizontal, KKPaddingSM)
		.background(
			RoundedRectangle(cornerRadius: CGFloat(KKRadiusMD))
				.fill(Color.kkAccent.opacity(isHovering ? 0.12 : 0))
		)
		.contentShape(RoundedRectangle(cornerRadius: CGFloat(KKRadiusSM)))
		.onHover { isHovering = $0 }
	}

	/// Clip count, project and age come from the manifest, not the filename - they
	/// change on every re-publish, and a filename that changed would strand the
	/// old file.
	private var age: String {
		Self.relative.localizedString(for: source.publishedAt, relativeTo: Date())
	}

	private func commit() {
		isEditing = false
		onRename(draft)
	}

	private static let relative: RelativeDateTimeFormatter = {
		let f = RelativeDateTimeFormatter()
		f.unitsStyle = .abbreviated
		return f
	}()
}
