/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

struct AIConfigTab: View {
	@StateObject private var keyState = AIKeyState.shared
	@State private var keyInput: String = ""
	@State private var savedKeyExists: Bool = false
	@State private var status: Status = .idle

	enum Status: Equatable {
		case idle
		case validating
		case success
		case failure(String)
	}

	private var provider: AIProvider { keyState.activeProvider }

	var body: some View {
		if provider == .local {
			LocalModelsView()
		} else {
			keyEntryForm
		}
	}

	private var keyEntryForm: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 8) {
				Text(AILoc("API Key"))
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(Color.aiSecondaryText)
				SecureField(
					savedKeyExists
						? AILoc("Saved - paste to replace")
						: AILoc("Paste \(provider.keyPrefixHint ?? "")…"),
					text: $keyInput
				)
				.textFieldStyle(.roundedBorder)
				.disabled(status == .validating)
			}

			statusLine

			HStack {
				if let consoleURL = provider.keyConsoleURL {
					Link(AILoc("Get a key"), destination: consoleURL)
						.font(.caption)
				}
				Spacer()
				if savedKeyExists {
					Button(AILoc("Delete"), role: .destructive) { delete() }
						.disabled(status == .validating)
				}
				Button {
					Task { await saveWithValidation() }
				} label: {
					if status == .validating {
						ProgressView().controlSize(.small)
					} else {
						Text(AILoc("Save"))
					}
				}
				.keyboardShortcut(.defaultAction)
				.disabled(keyInput.isEmpty || status == .validating)
			}
		}
		.onAppear { refreshState() }
		.onChange(of: keyState.activeProvider) { _, _ in refreshState() }
	}

	@ViewBuilder
	private var statusLine: some View {
		switch status {
		case .idle:
			EmptyView()
		case .validating:
			Label(AILoc("Testing connection"), systemImage: "ellipsis.circle")
				.font(.caption)
				.foregroundStyle(Color.aiSecondaryText)
		case .success:
			Label(AILoc("Key works"), systemImage: "checkmark.circle.fill")
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
			status = .failure(AILoc("Couldn't delete: \(error.localizedDescription)"))
		}
	}
}
