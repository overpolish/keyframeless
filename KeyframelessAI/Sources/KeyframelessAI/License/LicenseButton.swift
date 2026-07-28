/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

public struct LicenseButton: View {
	@State private var showPopover = false
	@StateObject private var state: LicenseState

	let productName: String
	let purchaseURL: URL?
	let tint: Color
	let onActivated: (() -> Void)?

	/// `tint` colors the Trial label. Plugins pass the kit's host-matching
	/// accent (this package can't import KeyframelessKit, so the token comes in
	/// from the caller); the default suits the workflow extension.
	public init(
		productID: String,
		productName: String,
		purchaseURL: URL? = nil,
		tint: Color = .accentColor,
		onActivated: (() -> Void)? = nil
	) {
		_state = StateObject(wrappedValue: LicenseState.shared(for: productID))
		self.productName = productName
		self.purchaseURL = purchaseURL
		self.tint = tint
		self.onActivated = onActivated
	}

	public var body: some View {
		// The button exists only while unactivated. It survives the moment of
		// activation with the popover still open (so the success state has an
		// anchor), then disappears for good once the popover closes.
		if !state.isActivated || showPopover {
			Button {
				state.refresh()
				showPopover.toggle()
			} label: {
				Text(AILoc("Trial"))
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(tint)
					.contentShape(Rectangle())
			}
			.buttonStyle(.borderless)
			.help(AILoc("Activate license"))
			.popover(isPresented: $showPopover, arrowEdge: .top) {
				LicenseActivationPopover(
					state: state,
					productName: productName,
					purchaseURL: purchaseURL,
					onActivated: onActivated)
			}
		}
	}
}

struct LicenseActivationPopover: View {
	@ObservedObject var state: LicenseState
	let productName: String
	let purchaseURL: URL?
	var onActivated: (() -> Void)?

	@State private var licenseKey = ""
	@State private var isActivating = false
	@State private var errorText: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if state.isActivated {
				activatedContent
			} else {
				activationForm
			}
		}
		.padding(14)
		// A VStack sizes to its widest child, so without an explicit alignment
		// the whole block gets CENTERED in the 300pt popover - and the activated
		// state's two lines have very different widths, so the short one visibly
		// hung off-centre against the long one. The activation form never showed
		// it (its text field already fills the width).
		.frame(width: 300, alignment: .leading)
		.fixedSize(horizontal: false, vertical: true)
		.animation(.easeInOut(duration: 0.18), value: state.isActivated)
		.popoverGlassFix()
	}

	private var activatedContent: some View {
		// Centred as a block: it's a two-line confirmation, not a form, and the
		// lines' very different widths read as misaligned when leading. The
		// maxWidth is what makes it centre on the POPOVER rather than on the
		// widest line (a VStack otherwise shrinks to fit its content).
		VStack(alignment: .center, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "checkmark.seal.fill")
					.foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.45))
				Text(String(format: AILoc("%@ is activated"), productName))
					.font(.system(size: 12, weight: .semibold))
			}
			if let email = state.record?.buyerEmail, !email.isEmpty {
				Text(String(format: AILoc("Licensed to %@"), email))
					.font(.system(size: 11))
					.foregroundStyle(Color.aiSecondaryText)
					.multilineTextAlignment(.center)
			}
		}
		.frame(maxWidth: .infinity)
	}

	private var activationForm: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(String(format: AILoc("Activate %@"), productName))
				.font(.system(size: 12, weight: .semibold))
			Text(AILoc("Paste the license key from your Payhip receipt."))
				.font(.system(size: 11))
				.foregroundStyle(Color.aiSecondaryText)
			TextField(AILoc("License key"), text: $licenseKey)
				.textFieldStyle(.roundedBorder)
				.disabled(isActivating)
				.onSubmit(activate)
			if let errorText {
				Text(errorText)
					.font(.system(size: 11))
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				if let purchaseURL {
					Link(AILoc("Purchase license"), destination: purchaseURL)
						.font(.caption)
				}
				Spacer()
				if isActivating {
					ProgressView()
						.controlSize(.small)
				} else {
					Button(AILoc("Activate"), action: activate)
						.keyboardShortcut(.defaultAction)
						.disabled(
							licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
								.isEmpty)
				}
			}
		}
	}

	private func activate() {
		guard !isActivating else { return }
		errorText = nil
		isActivating = true
		let key = licenseKey
		Task { @MainActor in
			do {
				try await state.activate(licenseKey: key)
				onActivated?()
			} catch {
				errorText = error.localizedDescription
			}
			isActivating = false
		}
	}
}
