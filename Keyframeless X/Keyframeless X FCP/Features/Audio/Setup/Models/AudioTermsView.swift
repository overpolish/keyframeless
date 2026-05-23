/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct AudioTermsView: View {
	@ObservedObject var manager: AudioModelManager
	@State private var input: String = ""
	@FocusState private var focused: Bool

	private static let maxTerms = 15
	private static let maxTermLength = 30

	private var validationError: String? {
		let trimmed = input.trimmingCharacters(in: .whitespaces)
		if trimmed.isEmpty { return nil }
		if trimmed.count > Self.maxTermLength { return "Max \(Self.maxTermLength) characters" }
		if manager.terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
			return "Already added"
		}
		return nil
	}

	private var canAdd: Bool {
		let trimmed = input.trimmingCharacters(in: .whitespaces)
		return !trimmed.isEmpty
			&& validationError == nil
			&& manager.terms.count < Self.maxTerms
	}

	private func addTerm() {
		let trimmed = input.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, validationError == nil, manager.terms.count < Self.maxTerms
		else { return }
		manager.terms.append(trimmed)
		input = ""
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			HStack(alignment: .firstTextBaseline) {
				Text("Terms")
					.font(.title3)
					.foregroundStyle(.secondary)
				Spacer()
				HelperText(String(localized: "Optional"))
			}
			.frame(height: 20)

			VStack(spacing: 0) {
				HStack(spacing: KKSpacingSM) {
					TextField("Add a term…", text: $input)
						.textFieldStyle(.plain)
						.font(.system(size: 12))
						.focused($focused)
						.onChange(of: input) {
							if input.count > Self.maxTermLength + 5 {
								input = String(input.prefix(Self.maxTermLength + 5))
							}
						}
						.onSubmit { addTerm() }

					if let error = validationError {
						Text(error)
							.font(.system(size: 10))
							.foregroundStyle(Color.kkError)
					} else {
						let count = manager.terms.count
						Text("\(count)/\(Self.maxTerms)")
							.font(.system(size: 10).monospacedDigit())
							.foregroundStyle(
								count >= Self.maxTerms
									? Color.kkError
									: count >= 12
										? Color.kkWarning
										: Color.secondary.opacity(0.4)
							)
					}

					Button(action: addTerm) {
						Image(systemName: "return")
							.font(.system(size: 10))
							.foregroundStyle(
								canAdd
									? Color.kkAccent
									: Color.secondary.opacity(0.4))
					}
					.buttonStyle(.plain)
					.disabled(!canAdd)
				}
				.padding(.horizontal, KKPaddingLG)
				.padding(.vertical, KKSpacingLG)
				.overlay(
					Rectangle()
						.frame(height: KKBorderWidthXS)
						.foregroundStyle(Color.secondary.opacity(0.15)),
					alignment: .bottom
				)

				if manager.terms.isEmpty {
					VStack {
						Spacer()
						Text("Keywords to help the AI catch names and jargon.")
							.font(.system(size: 11))
							.foregroundStyle(.tertiary)
							.multilineTextAlignment(.center)
						Spacer()
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					ScrollView {
						LazyVStack(spacing: 0) {
							ForEach(manager.terms, id: \.self) { term in
								TermRow(term: term) {
									manager.terms.removeAll { $0 == term }
								}
							}
						}
						.padding(KKPaddingMD)
					}
				}
			}
			.frame(maxHeight: .infinity)
			.kkPanel()
			.overlay {
				if manager.currentEngine == .parakeet && !manager.hasCtcModel {
					ParakeetTermsLockOverlay(manager: manager)
				}
			}
		}
	}
}

private struct ParakeetTermsLockOverlay: View {
	@ObservedObject var manager: AudioModelManager

	var body: some View {
		let isDownloading = manager.downloadingModel != nil
		ZStack {
			Rectangle()
				.fill(.ultraThinMaterial)
			VStack(spacing: KKSpacingMD) {
				Image(systemName: "lock.fill")
					.font(.system(size: 16))
					.foregroundStyle(.secondary)
				Text("Terms engine not installed.")
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
				Button {
					guard let id = manager.selectedModel else { return }
					Task { await manager.retryDownloadCtcEngine(triggeredBy: id) }
				} label: {
					HStack(spacing: 3) {
						if isDownloading {
							ProgressView()
								.controlSize(.small)
						} else {
							Image(systemName: "arrow.down.circle")
						}
						Text(isDownloading ? "Downloading…" : "Download")
					}
					.font(.system(size: 11))
					.foregroundStyle(Color.kkAccent)
				}
				.buttonStyle(.plain)
				.disabled(isDownloading)
			}
			.padding(KKPaddingLG)
		}
		.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD + 4))
	}
}

private struct TermRow: View {
	let term: String
	let onRemove: () -> Void

	var body: some View {
		HStack(spacing: KKSpacingLG) {
			Text(term)
				.font(.system(size: 12))
				.frame(maxWidth: .infinity, alignment: .leading)
			Button(action: onRemove) {
				Image(systemName: "xmark")
					.font(.system(size: 9, weight: .medium))
					.foregroundStyle(Color.secondary.opacity(0.6))
					.padding(KKPaddingSM)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKSpacingMD)
	}
}
