/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

public struct AIKeySettingsView: View {
	@State private var provider: AIProvider = .anthropic
	@State private var keyInput: String = ""
	@State private var savedKeyExists: Bool = false
	@State private var status: Status = .idle

	enum Status: Equatable {
		case idle
		case validating
		case success
		case failure(String)
	}

	public init() {}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			ProviderPill(selection: $provider)
				.frame(maxWidth: .infinity, alignment: .center)
				.onChange(of: provider) { _, _ in refreshState() }

			HStack(spacing: 8) {
				Text("API Key")
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(.secondary)
				SecureField(
					savedKeyExists
						? "Saved - paste to replace" : "Paste \(provider.keyPrefixHint)…",
					text: $keyInput
				)
				.textFieldStyle(.roundedBorder)
				.disabled(status == .validating)
			}

			statusLine

			HStack {
				Link("Get a key", destination: provider.keyConsoleURL)
					.font(.caption)
				Spacer()
				if savedKeyExists {
					Button("Delete", role: .destructive) { delete() }
						.disabled(status == .validating)
				}
				Button {
					Task { await saveWithValidation() }
				} label: {
					if status == .validating {
						ProgressView().controlSize(.small)
					} else {
						Text("Save")
					}
				}
				.keyboardShortcut(.defaultAction)
				.disabled(keyInput.isEmpty || status == .validating)
			}
		}
		.padding(16)
		.frame(width: 340)
		.onAppear { refreshState() }
		.modifier(PopoverGlassFix())
	}

	@ViewBuilder
	private var statusLine: some View {
		switch status {
		case .idle:
			EmptyView()
		case .validating:
			Label("Testing connection…", systemImage: "ellipsis.circle")
				.font(.caption)
				.foregroundStyle(.secondary)
		case .success:
			Label("Key works", systemImage: "checkmark.circle.fill")
				.font(.caption)
				.foregroundStyle(.green)
		case .failure(let msg):
			Label(msg, systemImage: "xmark.circle.fill")
				.font(.caption)
				.foregroundStyle(.red)
		}
	}

	private func refreshState() {
		status = .idle
		keyInput = ""
		savedKeyExists = (try? AIKeychain.load(provider)) != nil
	}

	private func saveWithValidation() async {
		status = .validating
		do {
			try await AIKeyValidator.validate(keyInput, for: provider)
			try AIKeychain.save(keyInput, for: provider)
			keyInput = ""
			savedKeyExists = true
			status = .success
		} catch {
			status = .failure(error.localizedDescription)
		}
	}

	private func delete() {
		do {
			try AIKeychain.delete(provider)
			savedKeyExists = false
			status = .idle
		} catch {
			status = .failure("Couldn't delete: \(error.localizedDescription)")
		}
	}
}

private struct ProviderPill: View {
	@Binding var selection: AIProvider

	var body: some View {
		HStack(spacing: 4) {
			ForEach(AIProvider.allCases) { p in
				let isSelected = selection == p
				Button {
					selection = p
				} label: {
					HStack(spacing: 6) {
						AIProviderLogo(provider: p)
							.frame(width: 13, height: 13)
						Text(p.displayName)
							.font(.system(size: 12, weight: .medium))
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 6)
					.background {
						if isSelected {
							Capsule().fill(Color.accentColor)
						}
					}
					.foregroundStyle(isSelected ? Color.white : .secondary)
					.contentShape(Capsule())
				}
				.buttonStyle(.plain)
			}
		}
		.padding(4)
		.background(Capsule().fill(Color.white.opacity(0.08)))
	}
}
