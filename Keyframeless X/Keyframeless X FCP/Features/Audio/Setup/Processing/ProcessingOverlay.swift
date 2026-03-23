/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct ProcessingOverlay: View {
	let statusLabel: String
	let progress: Double?
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
				ProgressView(value: progress)
					.frame(width: 180)
					.tint(Color.kkAccent)
				Text("\(Int(progress * 100))%")
					.font(.system(size: 12).monospacedDigit())
					.foregroundStyle(.secondary)
			}
		}
	}
}
