/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct ProcessingOverlay: View {
	let statusLabel: String
	let progress: Double?
	let estimatedTimeRemaining: String?
	let onCancel: () -> Void

	@State private var spinAngle: Double = 0
	@State private var appeared = false

	var body: some View {
		ZStack {
			Rectangle()
				.fill(.ultraThinMaterial)
				.ignoresSafeArea()

			VStack(spacing: 0) {
				spinningLogo
				progressContent
					.padding(.top, KKSpacingLG)
				Button("Cancel", action: onCancel)
					.buttonStyle(.plain)
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
					.padding(.top, 24)
			}
			.scaleEffect(appeared ? 1 : 0.8)
			.opacity(appeared ? 1 : 0)
		}
		.contentShape(Rectangle())
		.onAppear {
			withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
				appeared = true
			}
			withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
				spinAngle = 360
			}
		}
	}

	private var spinningLogo: some View {
		Image("keyframeless-logo")
			.resizable()
			.scaledToFit()
			.frame(width: 64, height: 64)
			.rotation3DEffect(
				.degrees(spinAngle),
				axis: (x: 0, y: 1, z: 0),
				perspective: 0.5
			)
	}

	private var progressContent: some View {
		VStack(spacing: KKSpacingSM) {
			Text(statusLabel)
				.font(.system(size: 14, weight: .medium))
			if let progress {
				let clamped = max(0, min(1, progress))
				ProgressView(value: clamped)
					.frame(width: 180)
					.tint(Color.kkAccent)
				HStack {
					Text("\(Int(clamped * 100))%")
						.font(.system(size: 12).monospacedDigit())
						.foregroundStyle(.secondary)
					if let estimatedTimeRemaining {
						Spacer()
						Text(estimatedTimeRemaining)
							.font(.system(size: 12))
							.foregroundStyle(.tertiary)
					}
				}
				.frame(width: 180)
			}
		}
	}
}
